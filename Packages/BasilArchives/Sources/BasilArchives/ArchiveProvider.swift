import BasilCore
import BasilVFS
import Darwin
import Dispatch
import Foundation
import Synchronization

extension ProviderID {
    public static let archive = ProviderID("archive")
}

/// One archive shown as a read-only folder tree. Its location's container is the archive file.
///
/// Reading goes through the backend's session on the provider's own serial queue (libarchive
/// handles are not thread safe and calls block). It conforms to `WritableProvider` so the copy
/// engine can extract from it; every mutating call throws `.unsupported`.
public final class ArchiveProvider: WritableProvider, @unchecked Sendable {
    public let location: ProviderLocation
    public var capabilities: ProviderCapabilities { [.read, .symlinks] }

    private let backend: any ArchiveBackend
    /// The local file the backend reads: the archive itself, or a temporary copy of a nested one.
    private let url: URL
    private let byContent: Bool
    private let temporaryCopy: Bool
    private let queue: DispatchQueue

    /// Index and the archive file's state when it was built. Read from any thread.
    private let state: Mutex<(index: ArchiveIndex, stamp: Stamp?)>
    /// Asks for the password of encrypted entries (the UI's prompt), and the one that worked.
    private let passwords: (any ContainerPasswords)?
    private let password: Mutex<String?>
    /// The password question in progress, so reads waiting at the same time share one prompt.
    private let passwordQuestion = Mutex<Task<String, Error>?>(nil)

    /// Only touched on `queue`.
    private var session: (any ArchiveReadSession)?
    /// Counts reads, so an idle session can be closed (only touched on `queue`).
    private var reads = 0
    /// A session unused this long is closed: it may hold a 7zz process or an open file.
    static let sessionIdleTimeout: DispatchTimeInterval = .seconds(10)

    struct Stamp: Equatable { var size: Int64; var mtime: Int; var mtimeNanos: Int; var inode: UInt64 }

    /// The names are encrypted too (the archive could not be listed without the password).
    let namesEncrypted: Bool

    init(location: ProviderLocation, backend: any ArchiveBackend, url: URL, byContent: Bool,
         entries: [ArchiveEntry], temporaryCopy: Bool,
         passwords: (any ContainerPasswords)? = nil, password: String? = nil) {
        self.passwords = passwords
        self.namesEncrypted = password != nil
        self.password = Mutex(password)
        self.location = location
        self.backend = backend
        self.url = url
        self.byContent = byContent
        self.temporaryCopy = temporaryCopy
        self.queue = DispatchQueue(label: "basil.archive.\(url.lastPathComponent)", qos: .userInitiated)
        self.state = Mutex((ArchiveIndex(entries), temporaryCopy ? nil : Self.stamp(url)))
    }

    deinit {
        if temporaryCopy { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// A single compressed file (notes.txt.gz): one entry, nothing to change.
    public var isSingleCompressedFile: Bool { LibArchiveBackend.allowsRaw(url) && state.withLock { $0.index.count } == 1 }

    func backendIs<T: ArchiveBackend>(_ type: T.Type) -> Bool { backend is T }

    /// The archive's display name, for logs and errors.
    var archiveName: String { location.container?.name ?? url.lastPathComponent }

    // MARK: Blocking work

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                UTF8Locale.use() // per thread: a serial queue does not always run on the same one
                continuation.resume(with: Result { try body() })
            }
        }
    }

    static func stamp(_ url: URL) -> Stamp? {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(size: st.st_size, mtime: st.st_mtimespec.tv_sec, mtimeNanos: st.st_mtimespec.tv_nsec, inode: st.st_ino)
    }

    /// Rereads the entry list when the archive file changed since it was indexed. Runs on `queue`.
    private func refreshIfChanged() throws -> ArchiveIndex {
        let (index, stamp) = state.withLock { ($0.index, $0.stamp) }
        guard !temporaryCopy else { return index }
        let now = Self.stamp(url)
        guard now != stamp else { return index }
        guard now != nil else { throw VFSError.notFound(location.container ?? .local(url.path)) }
        let entries = try backend.entries(of: url, byContent: byContent, password: password.withLock { $0 }) ?? []
        let fresh = ArchiveIndex(entries)
        session = nil
        state.withLock { $0 = (fresh, now) }
        return fresh
    }

    /// The entry at `path`, from an index that is current (the archive file is checked first).
    private func entry(_ path: VFSPath) async throws -> ArchiveEntry {
        guard path.location == location else { throw VFSError.noProvider(path.location) }
        let index = try await run { [self] in try refreshIfChanged() }
        guard let entry = index.entry(path.path) else { throw VFSError.notFound(path) }
        return entry
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            queue.async { [self] in
                UTF8Locale.use()
                do {
                    let index = try refreshIfChanged()
                    guard let folder = index.entry(directory.path) else { throw VFSError.notFound(directory) }
                    guard folder.kind == .directory else { throw VFSError.notADirectory(directory) }
                    let names = index.children[directory.path] ?? []
                    let items = names.compactMap { name -> FileItem? in
                        let path = directory.appending(name)
                        return index.entry(path.path).map { makeItem($0, path: path, index: index) }
                    }
                    continuation.yield(items)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        let entry = try await entry(path)
        let index = state.withLock { $0.index }
        return makeItem(entry, path: path, index: index)
    }

    /// Archives are not watched; a pane rereads (F2) and a changed archive is indexed again.
    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    private func makeItem(_ entry: ArchiveEntry, path: VFSPath, index: ArchiveIndex) -> FileItem {
        let kind: FileItem.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink(target: index.symlinkTargetKind(of: entry))
        case .other: .other
        }
        return FileItem(path: path, kind: kind, size: entry.size,
                        modified: entry.modified.map(Self.date), created: nil,
                        permissions: entry.permissions, isHidden: path.name.hasPrefix("."),
                        fileID: entry.ordinal >= 0 ? UInt64(entry.ordinal) : nil)
    }

    private static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    // MARK: Reading (the copy engine extracts through these)

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let entry = try await entry(path)
        let kind: FileFingerprint.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other: .other
        }
        return FileFingerprint(kind: kind, size: entry.size ?? 0,
                               modifiedNanos: entry.modified.map { Int64($0.tv_sec) * 1_000_000_000 + Int64($0.tv_nsec) },
                               fileID: entry.ordinal >= 0 ? UInt64(entry.ordinal) : nil)
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let entry = try await entry(path)
        let attributes = entry.macMetadata.map(AppleDouble.unpack) ?? []
        return FileMetadata(permissions: entry.ordinal >= 0 ? entry.permissions : nil, modified: entry.modified,
                            extendedAttributes: attributes)
    }

    /// Never the same volume as anything else, so the engine always streams out of an archive.
    public func volumeIdentifier(of path: VFSPath) async throws -> String? { nil }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        let entry = try await entry(path)
        guard entry.kind == .file else { throw VFSError.unsupported("reading \(path.name): it is not a file") }
        if entry.isEncrypted { _ = try await knownPassword() }
        return ArchiveFile(provider: self, entry: entry, name: path.name)
    }

    fileprivate func read(_ entry: ArchiveEntry, name: String, at offset: Int64, count: Int) async throws -> Data {
        try await run { [self] in
            if session == nil {
                session = backend.session(for: url, byContent: byContent, entries: state.withLock { $0.index.list },
                                          password: password.withLock { $0 })
            }
            reads += 1
            let mark = reads
            queue.asyncAfter(deadline: .now() + Self.sessionIdleTimeout) { [weak self] in
                guard let self, self.reads == mark else { return }
                self.session = nil
            }
            do {
                return try session!.read(entry, at: offset, count: count)
            } catch ArchiveError.encrypted {
                throw ArchiveError.encrypted(entry: name)
            } catch {
                session = nil // start over cleanly next time
                throw error
            }
        }
    }

    public func readSymlink(_ path: VFSPath) async throws -> String {
        let entry = try await entry(path)
        if entry.kind == .symlink, entry.symlinkTarget == nil, entry.isEncrypted {
            // 7z keeps a link's target as its data, encrypted with the files.
            _ = try await knownPassword()
            let data = try await read(entry, name: path.name, at: 0, count: Int(entry.size ?? 4096))
            return String(decoding: data, as: UTF8.self)
        }
        guard entry.kind == .symlink, let target = entry.symlinkTarget else { throw VFSError.unsupported("\(path.name) is not a link") }
        return target
    }

    // MARK: Changing (not supported yet: archives are read-only)

    private var readOnly: VFSError { .unsupported("changing \(archiveName): archives are read-only for now") }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] { throw readOnly }
    public func createFile(_ path: VFSPath) async throws -> any WritableFile { throw readOnly }
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws { throw readOnly }
    public func clone(_ from: VFSPath, to: VFSPath) async throws { throw VFSError.unsupported("cloning") }
    public func remove(_ path: VFSPath) async throws { throw readOnly }
    public func makeDirectory(_ path: VFSPath) async throws { throw readOnly }
    public func synchronize(_ path: VFSPath) async throws {}
    public func createSymlink(_ path: VFSPath, target: String) async throws { throw readOnly }

    // MARK: Passwords

    /// The archive's password: the one that opened it or worked before, else asked for (and
    /// checked on the archive) until one works or the prompt is cancelled.
    func knownPassword() async throws -> String {
        if let known = password.withLock({ $0 }) { return known }
        let question = passwordQuestion.withLock { current -> Task<String, Error> in
            if let current { return current }
            let task = Task { try await self.askForPassword() }
            current = task
            return task
        }
        do {
            let answer = try await question.value
            passwordQuestion.withLock { $0 = nil }
            return answer
        } catch {
            passwordQuestion.withLock { $0 = nil } // a later read asks again (Retry after Cancel)
            throw error
        }
    }

    private func askForPassword() async throws -> String {
        guard let passwords, let container = location.container else { throw ArchiveError.passwordNeeded(archive: archiveName) }
        var retry = false
        while true {
            guard let given = await passwords.password(for: container, retry: retry) else {
                throw ArchiveError.noPassword(archive: archiveName)
            }
            let backend = backend, url = url, byContent = byContent
            let works = try await run { [self] in
                try backend.checkPassword(given, url: url, byContent: byContent, entries: state.withLock { $0.index.list })
            }
            if works {
                passwords.accepted(given, for: container)
                password.withLock { $0 = given }
                try await run { [self] in session = nil } // the next read starts with the password
                return given
            }
            retry = true
        }
    }

    /// The entries the archive stores (no implied folders), from a current index.
    var explicitEntries: [ArchiveEntry] {
        state.withLock { $0.index.list }.filter { $0.ordinal >= 0 && $0.path != "/" }
    }

    var hasEncryptedEntries: Bool { state.withLock { $0.index.list.contains { $0.isEncrypted } } }

    // MARK: Test

    func test(progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String] {
        let password: String? = hasEncryptedEntries ? try await knownPassword() : self.password.withLock { $0 }
        let backend = backend, url = url, byContent = byContent
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await run {
                try backend.test(url, byContent: byContent, password: password) { fraction, entry in
                    progress(fraction, entry)
                    return !cancelled.withLock { $0 }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}

/// An entry opened for reading.
private struct ArchiveFile: ReadableFile {
    let provider: ArchiveProvider
    let entry: ArchiveEntry
    let name: String

    func read(at offset: Int64, count: Int) async throws -> Data {
        try await provider.read(entry, name: name, at: offset, count: count)
    }

    func close() async {}
}
