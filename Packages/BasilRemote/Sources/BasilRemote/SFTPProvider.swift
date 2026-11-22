import BasilCore
import BasilVFS
import CLibSSH2
import Darwin
import Foundation

extension ProviderID {
    public static let sftp = ProviderID("sftp")
}

/// Files on an SFTP server, through one SSH connection (`SSHConnection`). Paths are the server's
/// absolute paths. The copy engine writes through `.basil-partial-*` files, fsync@openssh.com and
/// posix-rename@openssh.com, so a finished copy appears at once and complete, like locally.
/// Remote folders are not watched: panes reread after Basil's own changes and on F2.
public final class SFTPProvider: WritableProvider, ConnectedProvider, @unchecked Sendable {
    public let location: ProviderLocation
    public var capabilities: ProviderCapabilities {
        [.read, .write, .randomAccessRead, .randomAccessWrite, .rename, .atomicRename, .setPermissions, .setDates, .symlinks]
    }

    let connection: SSHConnection
    public var connectionTitle: String { connection.endpoint.account }
    /// The folder the server starts in (the user's home there).
    public let home: String

    init(connection: SSHConnection, home: String) {
        self.connection = connection
        self.home = home
        location = ProviderLocation(provider: .sftp, instance: connection.endpoint.account)
    }

    public func disconnect() async {
        _ = try? await connection.run { [connection] in connection.close() }
    }

    public var maxTransferChunkSize: Int? { 1 << 20 }

    // MARK: Attributes

    static let attributeFlags = UInt(LIBSSH2_SFTP_ATTR_SIZE | LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_ACMODTIME)

    /// lstat (`follow` false) or stat on the queue.
    private func stat(_ sftp: OpaquePointer, _ path: VFSPath, follow: Bool) throws -> LIBSSH2_SFTP_ATTRIBUTES {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.path.withCString {
            libssh2_sftp_stat_ex(sftp, $0, UInt32(path.path.utf8.count), follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &attrs)
        }
        guard rc == 0 else { throw connection.error(rc, path, "Reading \(path.name)") }
        return attrs
    }

    private func exists(_ sftp: OpaquePointer, _ path: VFSPath) -> Bool {
        (try? stat(sftp, path, follow: false)) != nil
    }

    static func kind(_ attrs: LIBSSH2_SFTP_ATTRIBUTES) -> FileItem.Kind {
        guard attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else { return .file }
        switch Int32(attrs.permissions) & Int32(LIBSSH2_SFTP_S_IFMT) {
        case Int32(LIBSSH2_SFTP_S_IFDIR): return .directory
        case Int32(LIBSSH2_SFTP_S_IFREG): return .file
        case Int32(LIBSSH2_SFTP_S_IFLNK): return .symlink(target: .unknown)
        default: return .other
        }
    }

    /// A symlink's target kind, by following it once.
    private func linkTarget(_ sftp: OpaquePointer, _ path: VFSPath) -> FileItem.Kind.Target {
        guard let target = try? stat(sftp, path, follow: true) else { return .broken }
        if case .directory = Self.kind(target) { return .directory }
        return .file
    }

    private func item(_ sftp: OpaquePointer, _ path: VFSPath, _ attrs: LIBSSH2_SFTP_ATTRIBUTES) -> FileItem {
        var kind = Self.kind(attrs)
        if case .symlink = kind { kind = .symlink(target: linkTarget(sftp, path)) }
        let hasSize = attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0
        let hasTimes = attrs.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
        let isFile = if case .file = kind { true } else { false }
        return FileItem(
            path: path, kind: kind,
            size: isFile && hasSize ? Int64(attrs.filesize) : nil,
            modified: hasTimes ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime)) : nil,
            permissions: attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 ? UInt16(attrs.permissions & 0o7777) : nil,
            isHidden: path.name.hasPrefix(".")
        )
    }

    static func isDirectory(_ kind: FileItem.Kind) -> Bool {
        if case .directory = kind { return true }
        return false
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            connection.queue.async { [self] in
                do {
                    let sftp = try connection.channel()
                    let raw = directory.path
                    guard let handle = raw.withCString({
                        libssh2_sftp_open_ex(sftp, $0, UInt32(raw.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
                    }) else {
                        throw listError(sftp, directory)
                    }
                    defer { libssh2_sftp_close_handle(handle) }
                    var name = [CChar](repeating: 0, count: 4096)
                    var long = [CChar](repeating: 0, count: 4096)
                    var batch: [FileItem] = []
                    while true {
                        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
                        let count = libssh2_sftp_readdir_ex(handle, &name, name.count, &long, long.count, &attrs)
                        if count == 0 { break }
                        guard count > 0 else { throw connection.error(count, directory, "Listing \(directory.displayName)") }
                        let entry = String(decoding: name.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if entry == "." || entry == ".." { continue }
                        batch.append(item(sftp, directory.appending(entry), attrs))
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
        }
    }

    /// opendir failed: "not a folder" when the path is something else.
    private func listError(_ sftp: OpaquePointer, _ directory: VFSPath) -> Error {
        let rc = libssh2_session_last_errno(connection.session)
        let error = connection.error(rc, directory, "Listing \(directory.displayName)")
        // OpenSSH reports a file opened as a folder as "no such file".
        if connection.sftp != nil, let attrs = try? stat(sftp, directory, follow: true), !Self.isDirectory(Self.kind(attrs)) {
            return VFSError.notADirectory(directory)
        }
        return error
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            return item(sftp, path, try stat(sftp, path, follow: false))
        }
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        try await connection.run { [self] in
            let attrs = try stat(try connection.channel(), path, follow: false)
            let kind: FileFingerprint.Kind = switch Self.kind(attrs) {
            case .file: .file
            case .directory: .directory
            case .symlink: .symlink
            case .other: .other
            }
            let hasTimes = attrs.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
            return FileFingerprint(kind: kind, size: Int64(attrs.filesize),
                                   modifiedNanos: hasTimes ? Int64(attrs.mtime) * 1_000_000_000 : nil)
        }
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        try await connection.run { [self] in
            let attrs = try stat(try connection.channel(), path, follow: false)
            var metadata = FileMetadata()
            if attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 { metadata.permissions = UInt16(attrs.permissions & 0o7777) }
            if attrs.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0 {
                metadata.modified = timespec(tv_sec: Int(attrs.mtime), tv_nsec: 0)
                metadata.accessed = timespec(tv_sec: Int(attrs.atime), tv_nsec: 0)
            }
            return metadata
        }
    }

    /// Permissions and dates as SFTP attributes; what SFTP cannot store is left out quietly
    /// (the provider does not claim extended attributes, flags or creation dates).
    static func attributes(for metadata: FileMetadata) -> LIBSSH2_SFTP_ATTRIBUTES? {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        if let permissions = metadata.permissions {
            attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attrs.permissions = UInt(permissions & 0o7777)
        }
        if let modified = metadata.modified {
            attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)
            attrs.mtime = UInt(max(modified.tv_sec, 0))
            attrs.atime = UInt(max((metadata.accessed ?? modified).tv_sec, 0))
        }
        return attrs.flags == 0 ? nil : attrs
    }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        guard let wanted = Self.attributes(for: metadata) else { return [] }
        return try await connection.run { [self] in
            var attrs = wanted
            let sftp = try connection.channel()
            // Symlinks: SETSTAT follows the link, so their own dates and mode are left alone.
            if case .symlink = Self.kind(try stat(sftp, path, follow: false)) { return [] }
            let rc = path.path.withCString {
                libssh2_sftp_stat_ex(sftp, $0, UInt32(path.path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attrs)
            }
            if rc != 0 { return ["could not set permissions and dates (\(connection.error(rc, path, "Setting attributes").localizedDescription))"] }
            return []
        }
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            var info = LIBSSH2_SFTP_STATVFS()
            let rc = path.path.withCString { libssh2_sftp_statvfs(sftp, $0, path.path.utf8.count, &info) }
            // Without statvfs@openssh.com every path counts as one volume; a rename across
            // file systems then fails and the engine copies instead.
            return rc == 0 ? "sftp:\(location.instance):\(info.f_fsid)" : "sftp:\(location.instance)"
        }
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        try await open(path, flags: UInt(LIBSSH2_FXF_READ), mode: 0)
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        try await open(path, flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL), mode: 0o644)
    }

    private func open(_ path: VFSPath, flags: UInt, mode: Int) async throws -> SFTPFile {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            guard let handle = path.path.withCString({
                libssh2_sftp_open_ex(sftp, $0, UInt32(path.path.utf8.count), flags, mode, LIBSSH2_SFTP_OPENFILE)
            }) else {
                var error = connection.error(libssh2_session_last_errno(connection.session), path, "Opening \(path.name)")
                // OpenSSH reports an existing file as a plain failure.
                if flags & UInt(LIBSSH2_FXF_EXCL) != 0, case .failed = error, connection.sftp != nil, exists(sftp, path) {
                    error = .alreadyExists(path)
                }
                throw error
            }
            return SFTPFile(path: path, handle: handle, connection: connection, generation: connection.generation)
        }
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            let caseOnly = from.path != to.path && from.path.lowercased() == to.path.lowercased()
            if !replacing, !caseOnly, exists(sftp, to) { throw VFSError.alreadyExists(to) }
            let rc = from.path.withCString { a in
                to.path.withCString { b in
                    libssh2_sftp_posix_rename_ex(sftp, a, from.path.utf8.count, b, to.path.utf8.count)
                }
            }
            if rc == 0 { return }
            let error = connection.error(rc, from, "Renaming \(from.name)")
            guard case .unsupported = error else { throw error }
            // A server without posix-rename: the plain rename, which refuses an existing target.
            if replacing, exists(sftp, to) { try removeSync(sftp, to) }
            let plain = from.path.withCString { a in
                to.path.withCString { b in
                    libssh2_sftp_rename_ex(sftp, a, UInt32(from.path.utf8.count), b, UInt32(to.path.utf8.count),
                                           Int(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE))
                }
            }
            guard plain == 0 else { throw connection.error(plain, from, "Renaming \(from.name)") }
        }
    }

    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        throw VFSError.unsupported("cloning on an SFTP server")
    }

    public func remove(_ path: VFSPath) async throws {
        try await connection.run { [self] in try removeSync(try connection.channel(), path) }
    }

    private func removeSync(_ sftp: OpaquePointer, _ path: VFSPath) throws {
        let attrs = try stat(sftp, path, follow: false)
        let isDirectory = Self.isDirectory(Self.kind(attrs))
        let rc = path.path.withCString {
            isDirectory ? libssh2_sftp_rmdir_ex(sftp, $0, UInt32(path.path.utf8.count))
                        : libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.path.utf8.count))
        }
        guard rc == 0 else {
            let error = connection.error(rc, path, "Deleting \(path.name)")
            // OpenSSH reports a folder that is not empty as a plain failure.
            if isDirectory, case .failed = error { throw VFSError.directoryNotEmpty(path) }
            throw error
        }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            let rc = path.path.withCString { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(path.path.utf8.count), 0o755) }
            guard rc == 0 else {
                let error = connection.error(rc, path, "Making \(path.name)")
                if case .failed = error, exists(sftp, path) { throw VFSError.alreadyExists(path) }
                throw error
            }
        }
    }

    public func synchronize(_ path: VFSPath) async throws {
        let file = try await open(path, flags: UInt(LIBSSH2_FXF_READ), mode: 0)
        defer { Task { await file.close() } }
        try await file.synchronize()
    }

    public func readSymlink(_ path: VFSPath) async throws -> String {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = path.path.withCString {
                libssh2_sftp_symlink_ex(sftp, $0, UInt32(path.path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_READLINK)
            }
            guard count >= 0 else { throw connection.error(count, path, "Reading the link \(path.name)") }
            return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        try await connection.run { [self] in
            let sftp = try connection.channel()
            if exists(sftp, path) { throw VFSError.alreadyExists(path) }
            // OpenSSH's sftp-server takes the two paths in the opposite order to the SFTP draft
            // (link target first), and libssh2 sends them as given.
            let rc = target.withCString { t in
                path.path.withCString { p in
                    libssh2_sftp_symlink_ex(sftp, t, UInt32(target.utf8.count), UnsafeMutablePointer(mutating: p),
                                            UInt32(path.path.utf8.count), LIBSSH2_SFTP_SYMLINK)
                }
            }
            guard rc == 0 else { throw connection.error(rc, path, "Making the link \(path.name)") }
        }
    }
}

/// An open SFTP file handle. Reads and writes at explicit offsets on the connection's queue.
final class SFTPFile: ReadableFile, WritableFile, @unchecked Sendable {
    let path: VFSPath
    private let connection: SSHConnection
    // Only touched on the connection's queue.
    private var handle: OpaquePointer?
    private let generation: Int

    init(path: VFSPath, handle: OpaquePointer, connection: SSHConnection, generation: Int) {
        self.path = path
        self.handle = handle
        self.connection = connection
        self.generation = generation
    }

    /// The handle, when its connection is still the live one.
    private func live() throws -> OpaquePointer {
        guard let handle, connection.generation == generation, connection.sftp != nil else {
            throw VFSError.failed("The connection to \(connection.endpoint.host) was lost while \(path.name) was open")
        }
        return handle
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        try await connection.run { [self] in
            let handle = try live()
            libssh2_sftp_seek64(handle, UInt64(offset))
            var data = Data(count: count)
            var filled = 0
            while filled < count {
                let got = data.withUnsafeMutableBytes { raw in
                    libssh2_sftp_read(handle, raw.baseAddress!.advanced(by: filled).assumingMemoryBound(to: CChar.self), count - filled)
                }
                if got == 0 { break }
                guard got > 0 else { throw connection.error(Int32(got), path, "Reading \(path.name)") }
                filled += got
            }
            data.count = filled
            return data
        }
    }

    func write(_ data: Data, at offset: Int64) async throws {
        try await connection.run { [self] in
            let handle = try live()
            libssh2_sftp_seek64(handle, UInt64(offset))
            var written = 0
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while written < data.count {
                    let rc = libssh2_sftp_write(handle, base.advanced(by: written).assumingMemoryBound(to: CChar.self), data.count - written)
                    guard rc > 0 else { throw connection.error(Int32(rc), path, "Writing \(path.name)") }
                    written += rc
                }
            }
        }
    }

    func truncate(to length: Int64) async throws {
        try await connection.run { [self] in
            let handle = try live()
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            attrs.flags = UInt(LIBSSH2_SFTP_ATTR_SIZE)
            attrs.filesize = UInt64(length)
            let rc = libssh2_sftp_fstat_ex(handle, &attrs, 1)
            guard rc == 0 else { throw connection.error(rc, path, "Truncating \(path.name)") }
        }
    }

    /// fsync@openssh.com. A server without it cannot promise the data is on disk; that is not an error.
    func synchronize() async throws {
        try await connection.run { [self] in
            let rc = libssh2_sftp_fsync(try live())
            guard rc != 0 else { return }
            let error = connection.error(rc, path, "Flushing \(path.name)")
            if case .unsupported = error { return }
            throw error
        }
    }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        guard let wanted = SFTPProvider.attributes(for: metadata) else { return [] }
        return try await connection.run { [self] in
            var attrs = wanted
            let rc = libssh2_sftp_fstat_ex(try live(), &attrs, 1)
            if rc != 0 { return ["could not set permissions and dates (\(connection.error(rc, path, "Setting attributes").localizedDescription))"] }
            return []
        }
    }

    func close() async {
        _ = try? await connection.run { [self] in
            if let handle, connection.generation == generation, connection.sftp != nil { libssh2_sftp_close_handle(handle) }
            handle = nil
        }
    }
}
