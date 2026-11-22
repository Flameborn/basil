import BasilCore
import BasilVFS
import Darwin
import Foundation

extension ProviderID {
    /// Plain FTP.
    public static let ftp = ProviderID("ftp")
    /// FTPS explicit (AUTH TLS).
    public static let ftpes = ProviderID("ftpes")
    /// FTPS implicit (TLS from the start, port 990).
    public static let ftps = ProviderID("ftps")
}

/// Files on an FTP or FTPS server, through a pool of control connections (`FTPPool`). Paths are
/// the server's absolute paths. FTP has no random-access writes, no fsync and no atomic
/// replacing rename, so the copy engine writes each partial file from the start in one STOR
/// (rewriting it whole when the source changed), and the file is complete once the server
/// confirmed the transfer (226). Remote folders are not watched.
public final class FTPProvider: WritableProvider, ConnectedProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let pool: FTPPool
    let features: FTPFeatures
    public let home: String
    public var homeDirectory: VFSPath { VFSPath(location: location, path: home) }
    public var connectionTitle: String { pool.endpoint.account }

    public var capabilities: ProviderCapabilities {
        var result: ProviderCapabilities = [.read, .write, .rename]
        if features.restStream { result.insert(.randomAccessRead) }
        if features.mfmt { result.insert(.setDates) }
        if features.mlstFacts.contains("unix.mode") { result.insert(.setPermissions) }
        return result
    }

    init(pool: FTPPool, features: FTPFeatures, home: String) {
        self.pool = pool
        self.features = features
        self.home = home
        location = ProviderLocation(provider: pool.endpoint.service, instance: pool.endpoint.account)
    }

    public func disconnect() async { await pool.closeAll() }

    public var maxTransferChunkSize: Int? { 1 << 20 }

    var encoding: FTPEncoding { pool.endpoint.encoding }

    // MARK: Items

    func item(_ entry: FTPEntry, in directory: VFSPath) -> FileItem {
        let kind: FileItem.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink(target: .unknown)
        case .other: .other
        }
        return FileItem(path: directory.appending(entry.name), kind: kind, size: entry.kind == .file ? entry.size : nil,
                        modified: entry.modified, permissions: entry.permissions, isHidden: entry.name.hasPrefix("."))
    }

    /// The entries of a folder, by MLSD or (older servers) LIST.
    func entries(_ session: FTPSession, _ directory: VFSPath) throws -> [FTPEntry] {
        let path = try FTPSession.checked(directory.path)
        do {
            if features.mlsd {
                let bytes = try session.listing("MLSD " + path)
                return Self.lines(bytes).compactMap { FTPListing.mlsd(encoding.decode($0)) }
            }
            let cwd = try session.command("CWD", path: path)
            guard cwd.isPositive else { throw FTPRefusal(reply: cwd) }
            let bytes = try session.listing(pool.endpoint.listHidden ? "LIST -a" : "LIST")
            let now = Date()
            return Self.lines(bytes).compactMap { FTPListing.list(encoding.decode($0), now: now) }
        } catch let refusal as FTPRefusal {
            throw explain(session, refusal, directory, listing: true)
        }
    }

    /// A refused path in VFS terms: not there, or not a folder.
    private func explain(_ session: FTPSession, _ refusal: FTPRefusal, _ path: VFSPath, listing: Bool) -> Error {
        if let item = try? lookUp(session, path) {
            if listing, item.kind != .directory { return VFSError.notADirectory(path) }
            return VFSError.failed("\(listing ? "Listing" : "Using") \(path.displayName) failed: \(refusal.reply.code) \(refusal.reply.text)")
        }
        return VFSError.notFound(path)
    }

    static func lines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        bytes.split(separator: 0x0A).map { $0.last == 0x0D ? $0.dropLast() : $0 }.filter { !$0.isEmpty }
    }

    /// One item: MLST, or the parent's listing on servers without it. nil when it does not exist.
    func lookUp(_ session: FTPSession, _ path: VFSPath) throws -> FTPEntry? {
        if path.isRoot { return FTPEntry(name: "/", kind: .directory) }
        if features.mlsd {
            let reply = try session.command("MLST", path: path.path)
            if reply.code == 250 {
                // 250-Listing /a\r\n type=file;size=1; /a\r\n250 End
                for line in reply.lines.dropFirst() where line.hasPrefix(" ") {
                    if var entry = FTPListing.mlsd(String(line.dropFirst())) {
                        entry.name = path.name
                        return entry
                    }
                }
                // "type=cdir" for a folder itself on some servers.
                if reply.lines.contains(where: { $0.lowercased().contains("type=cdir") || $0.lowercased().contains("type=dir") }) {
                    return FTPEntry(name: path.name, kind: .directory)
                }
            }
            if reply.code == 550 || reply.code == 450 { return nil }
            if reply.code != 250 { throw session.failure(reply, "Reading \(path.name)") }
            return nil
        }
        guard let parent = path.parent else { return nil }
        let siblings: [FTPEntry]
        do { siblings = try entries(session, parent) } catch VFSError.notFound { return nil }
        guard var entry = siblings.first(where: { $0.name == path.name }) else { return nil }
        // LIST has minutes at best: MDTM and SIZE give the exact time and size of a file.
        if entry.kind == .file {
            if features.mdtm, let reply = try? session.command("MDTM", path: path.path), reply.code == 213,
               let date = FTPListing.timestamp(reply.text) {
                entry.modified = date
                entry.preciseTime = true
            }
            if features.size, let reply = try? session.command("SIZE", path: path.path), reply.code == 213,
               let size = Int64(reply.text.trimmingCharacters(in: .whitespaces)) {
                entry.size = size
            }
        }
        return entry
    }

    func entry(_ session: FTPSession, _ path: VFSPath) throws -> FTPEntry {
        guard let entry = try lookUp(session, path) else { throw VFSError.notFound(path) }
        return entry
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let entries = try await pool.run { [self] session in try entries(session, directory) }
                    var batch: [FileItem] = []
                    for entry in entries {
                        batch.append(item(entry, in: directory))
                        if batch.count == 500 {
                            continuation.yield(batch)
                            batch = []
                        }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        let found = try await pool.run { [self] session in try entry(session, path) }
        guard let parent = path.parent else {
            return FileItem(path: path, kind: .directory)
        }
        var renamed = found
        renamed.name = path.name
        return item(renamed, in: parent)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let entry = try await pool.run { [self] session in try entry(session, path) }
        let kind: FileFingerprint.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other: .other
        }
        let nanos = entry.modified.map { Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded()) }
        return FileFingerprint(kind: kind, size: entry.size ?? 0, modifiedNanos: nanos)
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let entry = try await pool.run { [self] session in try entry(session, path) }
        var metadata = FileMetadata()
        metadata.permissions = entry.permissions
        if let modified = entry.modified {
            let seconds = modified.timeIntervalSince1970
            metadata.modified = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1e9))
        }
        return metadata
    }

    /// MFMT for the date and SITE CHMOD for the permissions, where the server has them.
    /// Anything FTP cannot store (extended attributes, flags, creation dates) is left out quietly.
    func apply(_ metadata: FileMetadata, to path: VFSPath, on session: FTPSession) throws -> [String] {
        var warnings: [String] = []
        if let modified = metadata.modified, features.mfmt {
            let stamp = FTPListing.timestamp(Date(timeIntervalSince1970: TimeInterval(modified.tv_sec)))
            let reply = try session.command("MFMT \(stamp)", path: path.path)
            if !reply.isPositive { warnings.append("could not set the date (\(reply.code) \(reply.text))") }
        }
        if let permissions = metadata.permissions, features.mlstFacts.contains("unix.mode") {
            let reply = try session.command("SITE CHMOD \(String(permissions & 0o7777, radix: 8))", path: path.path)
            if !reply.isPositive { warnings.append("could not set permissions (\(reply.code) \(reply.text))") }
        }
        return warnings
    }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        try await pool.run { [self] session in try apply(metadata, to: path, on: session) }
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        "\(location.provider.rawValue):\(location.instance)"
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        FTPReadFile(path: path, provider: self)
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        let session = try await pool.acquire()
        do {
            let data = try await session.run { [self] () throws -> FTPSocket in
                if try lookUp(session, path) != nil { throw VFSError.alreadyExists(path) }
                do {
                    return try session.openData("STOR " + FTPSession.checked(path.path))
                } catch let refusal as FTPRefusal {
                    throw VFSError.failed("Writing \(path.name) failed: \(refusal.reply.code) \(refusal.reply.text)")
                }
            }
            return FTPWriteFile(path: path, provider: self, session: session, data: data)
        } catch {
            pool.release(session)
            throw error
        }
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        try await pool.run { [self] session in
            let caseOnly = from.path != to.path && from.path.lowercased() == to.path.lowercased()
            let existing = caseOnly ? nil : try lookUp(session, to)
            if existing != nil, !replacing { throw VFSError.alreadyExists(to) }
            if try renameOnce(session, from, to) { return }
            // Servers that refuse to rename onto an existing file: remove it, then rename.
            // Not atomic: for a moment neither file has the target name.
            if replacing, let existing, existing.kind != .directory {
                let dele = try session.command("DELE", path: to.path)
                guard dele.isPositive else { throw session.failure(dele, "Replacing \(to.name)") }
                if try renameOnce(session, from, to) { return }
            }
            if try lookUp(session, from) == nil { throw VFSError.notFound(from) }
            throw VFSError.failed("Renaming \(from.name) failed: \(lastRefusal(session))")
        }
    }

    private func renameOnce(_ session: FTPSession, _ from: VFSPath, _ to: VFSPath) throws -> Bool {
        let rnfr = try session.command("RNFR", path: from.path)
        guard rnfr.code == 350 else {
            session.lastRefusal = "\(rnfr.code) \(rnfr.text)"
            return false
        }
        let rnto = try session.command("RNTO", path: to.path)
        if rnto.isPositive { return true }
        session.lastRefusal = "\(rnto.code) \(rnto.text)"
        return false
    }

    private func lastRefusal(_ session: FTPSession) -> String { session.lastRefusal ?? "refused" }

    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        throw VFSError.unsupported("cloning on an FTP server")
    }

    public func remove(_ path: VFSPath) async throws {
        try await pool.run { [self] session in
            let entry = try entry(session, path)
            if entry.kind == .directory {
                let reply = try session.command("RMD", path: path.path)
                if reply.isPositive { return }
                if let children = try? entries(session, path), !children.isEmpty { throw VFSError.directoryNotEmpty(path) }
                throw session.failure(reply, "Deleting \(path.name)")
            }
            let reply = try session.command("DELE", path: path.path)
            guard reply.isPositive else { throw session.failure(reply, "Deleting \(path.name)") }
        }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        try await pool.run { [self] session in
            let reply = try session.command("MKD", path: path.path)
            if reply.isPositive { return }
            if try lookUp(session, path) != nil { throw VFSError.alreadyExists(path) }
            throw session.failure(reply, "Making \(path.name)")
        }
    }

    /// FTP cannot flush a file; the server wrote it when it confirmed the transfer.
    public func synchronize(_ path: VFSPath) async throws {}

    /// The target as the listing shows it ("name -> target").
    public func readSymlink(_ path: VFSPath) async throws -> String {
        try await pool.run { [self] session in
            guard let parent = path.parent else { throw VFSError.notFound(path) }
            if features.mlsd, case .symlink(let target?) = try entry(session, path).kind { return target }
            // LIST shows link targets even when MLSD does not.
            let cwd = try session.command("CWD", path: parent.path)
            guard cwd.isPositive else { throw VFSError.notFound(path) }
            let bytes = try session.listing(pool.endpoint.listHidden || path.name.hasPrefix(".") ? "LIST -a" : "LIST")
            for line in Self.lines(bytes) {
                if let entry = FTPListing.list(encoding.decode(line)), entry.name == path.name,
                   case .symlink(let target?) = entry.kind {
                    return target
                }
            }
            throw VFSError.unsupported("reading where \(path.name) points on this FTP server")
        }
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links on an FTP server")
    }
}

/// A file being read from the server: one RETR, restarted at another offset (REST) when the
/// caller jumps. Reads are made one after another, as the copy engine does.
actor FTPReadFile: ReadableFile {
    let path: VFSPath
    let provider: FTPProvider
    private var session: FTPSession?
    private var data: FTPSocket?
    private var position: Int64 = 0
    private var atEnd = false

    init(path: VFSPath, provider: FTPProvider) {
        self.path = path
        self.provider = provider
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        if atEnd, offset >= position { return Data() }
        if data == nil || offset != position {
            await stop()
            let session = try await provider.pool.acquire()
            self.session = session
            let path = path
            let useRest = provider.features.restStream
            do {
                data = try await session.run {
                    do {
                        return try session.openData("RETR " + FTPSession.checked(path.path), restart: useRest ? offset : 0)
                    } catch let refusal as FTPRefusal {
                        throw VFSError.failed("Reading \(path.name) failed: \(refusal.reply.code) \(refusal.reply.text)")
                    }
                }
            } catch {
                provider.pool.release(session)
                self.session = nil
                throw error
            }
            position = useRest ? offset : 0
            atEnd = false
            // Without REST the bytes before the offset are read and dropped.
            while position < offset {
                let skipped = try await readData(Int(min(offset - position, 1 << 20)))
                if skipped.isEmpty { return Data() }
            }
        }
        return try await readData(count)
    }

    private func readData(_ count: Int) async throws -> Data {
        guard let session, let data else { throw VFSError.failed("\(path.name) is not open") }
        let path = path
        let bytes: Data
        do {
            bytes = try await session.run { try data.read(exactly: count) }
        } catch {
            await stop()
            throw VFSError.failed("Reading \(path.name) failed: \(error.localizedDescription)")
        }
        position += Int64(bytes.count)
        if bytes.count < count {
            // The end of the file: the server confirms the transfer.
            self.data = nil
            data.close()
            do {
                try await session.run { try session.finishTransfer("RETR " + path.path) }
            } catch {
                provider.pool.release(session)
                self.session = nil
                // Servers abort a transfer whose file was cut short meanwhile (451). When the
                // file is no longer than what arrived, that was its end; the copy engine sees the
                // changed size and reads again. Otherwise the transfer really failed.
                let read = position
                let size = try? await provider.pool.run { [provider] session in try provider.lookUp(session, path)?.size }
                guard let size = size ?? nil, size <= read else { throw error }
            }
            provider.pool.release(session)
            self.session = nil
            atEnd = true
        }
        return bytes
    }

    /// Ends a transfer early. FTP has no reliable way to stop one and keep the control
    /// connection (ABOR replies vary), so that session is dropped.
    private func stop() async {
        if let data {
            data.close()
            session?.broken = true
        }
        data = nil
        if let session { provider.pool.release(session) }
        session = nil
    }

    func close() async { await stop() }
}

/// The copy engine's partial file on the server: one STOR, written from the start. The upload
/// ends when the file is synchronized, its metadata applied, or it is closed; the server's 226
/// confirms that every byte arrived.
actor FTPWriteFile: WritableFile {
    nonisolated let path: VFSPath
    let provider: FTPProvider
    private var session: FTPSession?
    private var data: FTPSocket?
    private var written: Int64 = 0

    init(path: VFSPath, provider: FTPProvider, session: FTPSession, data: FTPSocket) {
        self.path = path
        self.provider = provider
        self.session = session
        self.data = data
    }

    func write(_ bytes: Data, at offset: Int64) async throws {
        guard offset == written else {
            throw VFSError.unsupported("writing in the middle of a file on an FTP server")
        }
        guard let session, let data else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        let path = path
        do {
            try await session.run { try data.write(bytes) }
        } catch {
            self.data = nil
            data.close()
            session.broken = true
            provider.pool.release(session)
            self.session = nil
            throw VFSError.failed("Writing \(path.name) failed: \(error.localizedDescription)")
        }
        written += Int64(bytes.count)
    }

    func truncate(to length: Int64) async throws {
        guard length == written, data != nil else {
            throw VFSError.unsupported("cutting a file short on an FTP server")
        }
    }

    /// Ends the upload and waits for the server's confirmation.
    private func finish() async throws {
        guard let session, let data else { return }
        self.data = nil
        let path = path
        do {
            try await session.run {
                data.finish()
                try session.finishTransfer("STOR " + path.path)
            }
        } catch {
            provider.pool.release(session)
            self.session = nil
            throw error
        }
        provider.pool.release(session)
        self.session = nil
    }

    func synchronize() async throws { try await finish() }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        try await finish()
        let provider = provider
        let path = path
        return try await provider.pool.run { session in try provider.apply(metadata, to: path, on: session) }
    }

    func close() async {
        try? await finish()
    }
}
