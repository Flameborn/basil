import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization

/// One SMB server as one connection (location `smb` / "user@host"). "/" lists the server's
/// shares; "/Media/Photos" is the folder Photos of the share Media, read and written through
/// the share's mount point with `LocalProvider`. Shares are mounted when first used.
public final class SMBProvider: ConnectedProvider, WritableProvider, LocalBackedProvider, Sendable {
    public let location: ProviderLocation
    // No Trash: macOS cannot move items on SMB shares to the Trash, so F8 deletes permanently.
    public let capabilities: ProviderCapabilities = [
        .read, .write, .randomAccessRead, .randomAccessWrite, .rename, .atomicRename,
        .setPermissions, .setDates, .extendedAttrs, .clone, .watch, .symlinks,
    ]

    let endpoint: SMBEndpoint
    /// Kept in memory for mounting further shares and listing them again.
    private let password: String?
    private let local = LocalProvider()
    /// By share name in lower case (SMB share names ignore case).
    private let mounts = Mutex<[String: Mount]>([:])
    private let mounter = Mounter()

    struct Mount: Sendable {
        var share: String
        var path: String
        /// Basil mounted it, so Disconnect unmounts it.
        var ours: Bool
    }

    init(endpoint: SMBEndpoint, password: String?) {
        self.endpoint = endpoint
        self.password = password
        location = ProviderLocation(provider: .smb, instance: endpoint.account)
    }

    public var connectionTitle: String { endpoint.account }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/") }

    public func disconnect() async {
        let ours = mounts.withLock { list in
            defer { list.removeAll() }
            return list.values.filter(\.ours).map(\.path)
        }
        for path in ours { await SMBClient.unmount(path) }
    }

    /// The share mount points Basil made, for tests.
    var ownMounts: [String] { mounts.withLock { $0.values.filter(\.ours).map(\.path) } }

    // MARK: Paths

    /// A path inside a share, with its local counterpart.
    struct Resolved: Sendable {
        /// The share's top ("/Media").
        var top: VFSPath
        var mount: String
        var local: VFSPath

        func remote(_ path: VFSPath) -> VFSPath {
            guard path.location == .local, path.path == mount || path.path.hasPrefix(mount + "/") else { return path }
            return VFSPath(location: top.location, path: top.path + path.path.dropFirst(mount.count))
        }

        func remote(_ item: FileItem) -> FileItem {
            FileItem(path: remote(item.path), kind: item.kind, size: item.size, modified: item.modified,
                     created: item.created, permissions: item.permissions, isHidden: item.isHidden,
                     fileID: item.fileID)
        }

        /// Errors name the share's paths, not the mount point's.
        func translate(_ error: any Error) -> any Error {
            guard let error = error as? VFSError else { return error }
            return switch error {
            case .notFound(let p): VFSError.notFound(remote(p))
            case .notADirectory(let p): VFSError.notADirectory(remote(p))
            case .permissionDenied(let p): VFSError.permissionDenied(remote(p))
            case .posix(let code, let p): VFSError.posix(code: code, path: remote(p))
            case .alreadyExists(let p): VFSError.alreadyExists(remote(p))
            case .directoryNotEmpty(let p): VFSError.directoryNotEmpty(remote(p))
            default: error
            }
        }
    }

    private func share(of path: VFSPath) -> String? { path.components.first }

    /// The local path of `path`, mounting its share first. nil for "/".
    func resolve(_ path: VFSPath) async throws -> Resolved? {
        let parts = path.components
        guard let share = parts.first else { return nil }
        let mount = try await mounted(share)
        let rest = parts.dropFirst().joined(separator: "/")
        return Resolved(top: VFSPath(location: location, path: "/" + share), mount: mount,
                        local: .local(rest.isEmpty ? mount : mount + "/" + rest))
    }

    /// Runs `body` on the local path, with errors in the share's terms.
    private func onLocal<T: Sendable>(_ path: VFSPath, _ body: (Resolved) async throws -> T) async throws -> T {
        guard let resolved = try await resolve(path) else {
            throw VFSError.failed("Files and folders go inside a share, not next to the shares of \(endpoint.hostAndPort)")
        }
        do {
            return try await body(resolved)
        } catch {
            throw resolved.translate(error)
        }
    }

    /// The mount point of a share, mounting it when needed.
    private func mounted(_ share: String) async throws -> String {
        let key = share.lowercased()
        if let known = mounts.withLock({ $0[key] }) {
            if SMBClient.isMounted(known.path) { return known.path }
            // Ejected meanwhile (in Finder): mount it again.
            _ = mounts.withLock { $0.removeValue(forKey: key) }
        }
        return try await mounter.run { [self] in
            if let known = mounts.withLock({ $0[key] }) { return known.path }
            let mount: Mount
            if let existing = SMBClient.mountPoint(of: share, on: endpoint) {
                mount = Mount(share: share, path: existing, ours: false)
            } else {
                do {
                    let path = try await SMBClient.mount(share, endpoint: endpoint, password: password)
                    mount = Mount(share: share, path: path, ours: true)
                } catch let error as SMBError where error.code == EEXIST {
                    // Mounted by someone else just now.
                    guard let existing = SMBClient.mountPoint(of: share, on: endpoint) else { throw error }
                    mount = Mount(share: share, path: existing, ours: false)
                }
            }
            mounts.withLock { $0[key] = mount }
            return mount.path
        }
    }

    /// Serialises mounting, so two reads of a new share mount it once.
    actor Mounter {
        func run(_ body: @Sendable () async throws -> String) async throws -> String { try await body() }
    }

    public func localPath(of path: VFSPath) -> String? {
        let parts = path.components
        guard let share = parts.first, let mount = mounts.withLock({ $0[share.lowercased()] }) else { return nil }
        let rest = parts.dropFirst().joined(separator: "/")
        return rest.isEmpty ? mount.path : mount.path + "/" + rest
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if directory.isRoot {
                        let names = try await SMBClient.shares(endpoint, password: password)
                        continuation.yield(names.map { FileItem(path: directory.appending($0), kind: .directory) })
                    } else {
                        try await onLocal(directory) { resolved in
                            for try await batch in local.list(resolved.local) {
                                continuation.yield(batch.map(resolved.remote))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: path, kind: .directory) }
        return try await onLocal(path) { resolved in
            let item = try await local.item(at: resolved.local)
            return resolved.remote(item)
        }
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? {
        guard !directory.isRoot else { return nil }
        return AsyncStream { continuation in
            let task = Task {
                guard let resolved = try? await resolve(directory), let changes = local.watch(resolved.local) else {
                    return continuation.finish()
                }
                for await change in changes {
                    switch change {
                    case .item(let path): continuation.yield(.item(resolved.remote(path)))
                    case .reloadAll: continuation.yield(.reloadAll)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        if path.isRoot { return FileFingerprint(kind: .directory, size: 0) }
        return try await onLocal(path) { resolved in
            // smbfs answers stat from its attribute cache for a few seconds, so a file changed
            // on the server by anything but this Mac looks unchanged. Opening it asks the
            // server and refreshes the cache. Symlinks are not opened (O_NOFOLLOW fails).
            let file = resolved.local.path
            try await SMBClient.run {
                let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                if fd >= 0 { close(fd) }
            }
            return try await local.fingerprint(of: resolved.local)
        }
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        if path.isRoot { return FileMetadata() }
        return try await onLocal(path) { try await local.metadata(of: $0.local) }
    }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        if path.isRoot { return [] }
        return try await onLocal(path) { try await local.applyMetadata(metadata, to: $0.local) }
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        if path.isRoot { return nil }
        return try await onLocal(path) { try await local.volumeIdentifier(of: $0.local) }
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        try await onLocal(path) { try await local.openForReading($0.local, bypassCache: bypassCache) }
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        try refuseShareLevel(path, "Files")
        return try await onLocal(path) { resolved in
            SMBFile(inner: try await local.createFile(resolved.local), path: path, resolved: resolved)
        }
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        guard from.components.count > 1, to.components.count > 1 else {
            throw VFSError.failed("Shares cannot be renamed from Basil")
        }
        guard share(of: from)?.lowercased() == share(of: to)?.lowercased() else {
            throw VFSError.unsupported("rename between shares")
        }
        try await onLocal(from) { resolved in
            let target = try await resolve(to)!.local
            try await local.rename(resolved.local, to: target, replacing: replacing)
        }
    }

    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        guard share(of: from)?.lowercased() == share(of: to)?.lowercased(), to.components.count > 1 else {
            throw VFSError.unsupported("clone between shares")
        }
        try await onLocal(from) { resolved in
            let target = try await resolve(to)!.local
            try await local.clone(resolved.local, to: target)
        }
    }

    public func remove(_ path: VFSPath) async throws {
        guard path.components.count > 1 else { throw VFSError.failed("Shares cannot be removed from Basil") }
        try await onLocal(path) { try await local.remove($0.local) }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        try refuseShareLevel(path, "Folders")
        try await onLocal(path) { try await local.makeDirectory($0.local) }
    }

    public func synchronize(_ path: VFSPath) async throws {
        try await onLocal(path) { try await local.synchronize($0.local) }
    }

    public func readSymlink(_ path: VFSPath) async throws -> String {
        try await onLocal(path) { try await local.readSymlink($0.local) }
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        try refuseShareLevel(path, "Links")
        try await onLocal(path) { try await local.createSymlink($0.local, target: target) }
    }

    /// Only shares are next to shares.
    private func refuseShareLevel(_ path: VFSPath, _ what: String) throws {
        if path.components.count < 2 {
            throw VFSError.failed("\(what) go inside a share, not next to the shares of \(endpoint.hostAndPort)")
        }
    }
}

/// The copy engine's partial file on a share, named by its share path.
struct SMBFile: WritableFile {
    let inner: any WritableFile
    let path: VFSPath
    let resolved: SMBProvider.Resolved

    func write(_ data: Data, at offset: Int64) async throws {
        do { try await inner.write(data, at: offset) } catch { throw resolved.translate(error) }
    }

    func truncate(to length: Int64) async throws {
        do { try await inner.truncate(to: length) } catch { throw resolved.translate(error) }
    }

    func synchronize() async throws {
        do { try await inner.synchronize() } catch { throw resolved.translate(error) }
    }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        do { return try await inner.apply(metadata) } catch { throw resolved.translate(error) }
    }

    func close() async { await inner.close() }
}
