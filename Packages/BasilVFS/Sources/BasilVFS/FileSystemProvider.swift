import BasilCore
import Foundation
import Synchronization

/// Errors any provider may surface. Providers wrap underlying errors where possible.
public enum VFSError: Error, Sendable, Equatable {
    case notFound(VFSPath)
    case notADirectory(VFSPath)
    case permissionDenied(VFSPath)
    case noProvider(ProviderLocation)
    case posix(code: Int32, path: VFSPath)
    case alreadyExists(VFSPath)
    case directoryNotEmpty(VFSPath)
    /// The provider or volume can't do this (for example clone on a non-APFS volume).
    case unsupported(String)
    /// Any other failure, already in words (a server's error message).
    case failed(String)
}

extension VFSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let p): "\(p) does not exist"
        case .notADirectory(let p): "\(p) is not a folder"
        case .permissionDenied(let p): "No permission for \(p)"
        case .noProvider(let l): "No provider for \(l.provider)"
        case .posix(let code, let p): "\(String(cString: strerror(code))) (\(p))"
        case .alreadyExists(let p): "\(p) already exists"
        case .directoryNotEmpty(let p): "\(p) is not empty"
        case .unsupported(let what): "Not supported: \(what)"
        case .failed(let message): message
        }
    }
}

/// A change reported by a provider's watcher. Consumers re-stat or re-list as needed.
public enum VFSChange: Sendable, Equatable {
    /// Something in the directory changed: the item at `path` was created, removed, modified or renamed.
    case item(VFSPath)
    /// Too many or unknown changes: reload the whole watched directory.
    case reloadAll
}

/// The interface every location type (local, SFTP, archive, ...) implements.
/// Mutating calls live in `WritableProvider`.
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
    let openers = Mutex<[any ContainerOpener]>([])
    let writers = Mutex<[any ContainerWriter]>([])
    let connectors = Mutex<[any RemoteConnector]>([])
    let annotators = Mutex<[any ColumnAnnotator]>([])
    private let passwordSource = Mutex<(any ContainerPasswords)?>(nil)

    /// Where encrypted containers get their passwords (the UI's prompt). nil: none can be opened.
    public var passwords: (any ContainerPasswords)? {
        get { passwordSource.withLock { $0 } }
        set { passwordSource.withLock { $0 = newValue } }
    }

    public init() {}

    /// Adds an opener for container files. Openers registered earlier are asked first,
    /// unless `first` puts this one ahead (a dedicated backend over a general one).
    public func register(opener: any ContainerOpener, first: Bool = false) {
        openers.withLock { first ? $0.insert(opener, at: 0) : $0.append(opener) }
    }

    public func register(_ provider: any FileSystemProvider) {
        providers.withLock { $0[provider.location] = provider }
    }

    public func unregister(_ location: ProviderLocation) {
        _ = providers.withLock { $0.removeValue(forKey: location) }
    }

    func allProviders() -> [any FileSystemProvider] {
        providers.withLock { Array($0.values) }
    }

    /// Removes every provider whose location matches; the providers are released outside the lock.
    func removeProviders(where matches: (ProviderLocation) -> Bool) -> [ProviderLocation] {
        let removed: [any FileSystemProvider] = providers.withLock { map in
            let gone = map.filter { matches($0.key) }
            for key in gone.keys { map[key] = nil }
            return Array(gone.values)
        }
        return removed.map(\.location)
    }

    public func provider(for location: ProviderLocation) throws -> any FileSystemProvider {
        guard let p = providers.withLock({ $0[location] }) else { throw VFSError.noProvider(location) }
        return p
    }

    /// The provider for `location` if it supports mutating calls.
    public func writableProvider(for location: ProviderLocation) throws -> any WritableProvider {
        guard let p = try provider(for: location) as? any WritableProvider else {
            throw VFSError.unsupported("writing to \(location.provider)")
        }
        return p
    }
}

/// A provider whose listings show a cheaper date than the one it keeps for each file (S3 lists
/// when it stored an object; the file's own date needs one more request per file). Features
/// that compare dates (Synchronize Directories) ask it for the kept dates of the files they use.
public protocol KeptDatesProvider: FileSystemProvider {
    /// The items with their kept modification dates where there is one (others unchanged).
    func withKeptDates(_ items: [FileItem]) async -> [FileItem]
}
