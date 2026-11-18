import BasilCore
import Synchronization

/// Errors any provider may surface. Providers wrap underlying errors where possible.
public enum VFSError: Error, Sendable, Equatable {
    case notFound(VFSPath)
    case notADirectory(VFSPath)
    case permissionDenied(VFSPath)
    case noProvider(ProviderLocation)
    case posix(code: Int32, path: VFSPath)
}

/// A change reported by a provider's watcher. Consumers re-stat or re-list as needed.
public enum VFSChange: Sendable, Equatable {
    /// Something in the directory changed: the item at `path` was created, removed, modified or renamed.
    case item(VFSPath)
    /// Too many or unknown changes: reload the whole watched directory.
    case reloadAll
}

/// The interface every location type (local, SFTP, archive, …) implements.
/// Mutating calls are added with the Operations milestone (M2).
public protocol FileSystemProvider: Sendable {
    var location: ProviderLocation { get }
    var capabilities: ProviderCapabilities { get }

    /// Streams a directory's entries in batches, so huge directories appear progressively.
    /// Does not include "." or "..".
    func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error>

    /// Metadata for a single item (follows nothing: a symlink returns `.symlink`).
    func item(at path: VFSPath) async throws -> FileItem

    /// Watches a directory for changes; `nil` if the provider can't watch.
    func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>?
}

/// Resolves a `ProviderLocation` to its provider instance.
/// Built-in providers and plugins register here the same way.
public final class ProviderRegistry: Sendable {
    private let providers = Mutex<[ProviderLocation: any FileSystemProvider]>([:])

    public init() {}

    public func register(_ provider: any FileSystemProvider) {
        providers.withLock { $0[provider.location] = provider }
    }

    public func unregister(_ location: ProviderLocation) {
        _ = providers.withLock { $0.removeValue(forKey: location) }
    }

    public func provider(for location: ProviderLocation) throws -> any FileSystemProvider {
        guard let p = providers.withLock({ $0[location] }) else { throw VFSError.noProvider(location) }
        return p
    }
}
