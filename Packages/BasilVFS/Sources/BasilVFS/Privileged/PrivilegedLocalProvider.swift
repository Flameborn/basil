import BasilCore
import Foundation

/// How Basil reaches the helper: one connection, one request at a time per call (calls may
/// overlap). The XPC transport is `PrivilegedXPCClient`; tests use `PrivilegedFileService` itself.
public protocol PrivilegedTransport: Sendable {
    func send(_ request: PrivilegedRequest) async throws -> PrivilegedReply
    /// Ends the connection; the helper closes its files and forgets the authorization.
    func close() async
}

/// A service in this process as the transport (tests).
extension PrivilegedFileService: PrivilegedTransport {
    public func send(_ request: PrivilegedRequest) async throws -> PrivilegedReply { await handle(request) }
    public func close() async { await closeAll() }
}

/// The local disk as root, through the administrator helper: every call runs in the helper as
/// the same `LocalProvider` call, so the copy engine keeps its strategies (rename, clone, the
/// stream pass with partial files, F_FULLFSYNC, metadata, atomic rename). Paths are local paths
/// under the location `.localAdministrator`. Registered only while an operation that needs it
/// runs (`AdministratorFiles`). New files belong to root, like files made with sudo.
public struct PrivilegedLocalProvider: WritableProvider, LocalBackedProvider {
    public let location = ProviderLocation.localAdministrator
    public let capabilities: ProviderCapabilities = [
        .read, .write, .randomAccessRead, .randomAccessWrite, .rename, .atomicRename,
        .setPermissions, .setDates, .extendedAttrs, .clone, .symlinks,
    ]
    let transport: any PrivilegedTransport

    public init(transport: any PrivilegedTransport) {
        self.transport = transport
    }

    /// Asks the user for the administrator password (macOS's dialog, shown by the helper).
    /// Throws `PrivilegedAccessDeclined` when it was cancelled.
    public func authorize(authorization: Data, prompt: String) async throws {
        _ = try await call(.authorize(authorization: authorization, prompt: prompt))
    }

    func call(_ request: PrivilegedRequest) async throws -> PrivilegedReply {
        let reply = try await transport.send(request)
        if case .failure(let error) = reply { throw error.vfsError }
        return reply
    }

    private func unexpected(_ reply: PrivilegedReply) -> VFSError {
        .failed("The administrator helper gave an unexpected answer (\(reply))")
    }

    public func localPath(of path: VFSPath) -> String? { path.path }

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let reply = try await call(.list(directory.path))
                    guard case .items(let items) = reply else { throw unexpected(reply) }
                    continuation.yield(items.map { $0.item(in: location) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        let reply = try await call(.item(path.path))
        guard case .item(let item) = reply else { throw unexpected(reply) }
        return item.item(in: location)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let reply = try await call(.fingerprint(path.path))
        guard case .fingerprint(let f) = reply else { throw unexpected(reply) }
        return f.fingerprint
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let reply = try await call(.metadata(path.path))
        guard case .metadata(let m) = reply else { throw unexpected(reply) }
        return m.metadata
    }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        let reply = try await call(.applyMetadata(WireMetadata(metadata), path.path))
        guard case .warnings(let w) = reply else { throw unexpected(reply) }
        return w
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        let reply = try await call(.volumeIdentifier(path.path))
        guard case .text(let id) = reply else { throw unexpected(reply) }
        return id
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        let reply = try await call(.openForReading(path.path, bypassCache: bypassCache))
        guard case .handle(let handle) = reply else { throw unexpected(reply) }
        return PrivilegedFile(provider: self, handle: handle, path: path)
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        let reply = try await call(.createFile(path.path))
        guard case .handle(let handle) = reply else { throw unexpected(reply) }
        return PrivilegedFile(provider: self, handle: handle, path: path)
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        _ = try await call(.rename(from.path, to.path, replacing: replacing))
    }

    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        _ = try await call(.clone(from.path, to.path))
    }

    public func remove(_ path: VFSPath) async throws {
        _ = try await call(.remove(path.path))
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        _ = try await call(.makeDirectory(path.path))
    }

    public func synchronize(_ path: VFSPath) async throws {
        _ = try await call(.synchronize(path.path))
    }

    public func readSymlink(_ path: VFSPath) async throws -> String {
        let reply = try await call(.readSymlink(path.path))
        guard case .text(let target?) = reply else { throw unexpected(reply) }
        return target
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        _ = try await call(.createSymlink(path.path, target: target))
    }

    /// Moves an item to the Trash of its volume as root: the user's ~/.Trash on the startup
    /// disk, "<volume>/.Trashes/<uid>" elsewhere. The item keeps its owner (macOS refuses to
    /// change the files inside an app), so emptying the Trash asks for a password in Finder.
    public func trash(_ path: VFSPath) async throws {
        _ = try await call(.trash(path.path, into: Self.trashFolder(for: path.path), owner: getuid()))
    }

    /// Removes an item with everything in it in one call.
    public func removeTree(_ path: VFSPath) async throws {
        _ = try await call(.removeTree(path.path))
    }

    static func trashFolder(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = URL(fileURLWithPath: path)
        let volume = (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeURLKey]))?.volume
        let homeVolume = (try? home.resourceValues(forKeys: [.volumeURLKey]))?.volume
        if let volume, volume.path != "/", volume != homeVolume {
            return volume.appendingPathComponent(".Trashes/\(getuid())").path
        }
        return home.appendingPathComponent(".Trash").path
    }

    /// Each chunk is one message; 4 MB keeps them small.
    public var maxTransferChunkSize: Int? { 4 * 1024 * 1024 }
}

/// A file the helper holds open.
struct PrivilegedFile: ReadableFile, WritableFile {
    let provider: PrivilegedLocalProvider
    let handle: UInt64
    let path: VFSPath

    func read(at offset: Int64, count: Int) async throws -> Data {
        let reply = try await provider.call(.read(handle, offset: offset, count: count))
        guard case .data(let data) = reply else { throw VFSError.failed("The administrator helper gave no data") }
        return data
    }

    func write(_ data: Data, at offset: Int64) async throws {
        _ = try await provider.call(.write(handle, data, offset: offset))
    }

    func truncate(to length: Int64) async throws {
        _ = try await provider.call(.truncate(handle, length: length))
    }

    func synchronize() async throws {
        _ = try await provider.call(.synchronizeFile(handle))
    }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        let reply = try await provider.call(.applyToFile(handle, WireMetadata(metadata)))
        guard case .warnings(let w) = reply else { return [] }
        return w
    }

    func close() async {
        _ = try? await provider.call(.close(handle))
    }
}
