import BasilCore
import Foundation
import Synchronization

/// Opens a file as a nested provider whose root shows the file's content (archives now,
/// disk images or plugin formats later). Built-in openers and plugins register in
/// `ProviderRegistry` the same way; the UI only asks the registry.
public protocol ContainerOpener: Sendable {
    /// The provider kind of the providers this opener makes ("archive").
    var provider: ProviderID { get }
    /// Cheap check by name: whether Enter should open a file with this name as a container.
    func recognizes(name: String) -> Bool
    /// Opens `file`. Returns nil when the content is not something this opener reads.
    /// `byContent` is true when the user asked to open the file whatever its name (Cmd+PageDown).
    func open(_ file: FileItem, byContent: Bool, registry: ProviderRegistry) async throws -> (any FileSystemProvider)?
    /// Reads the whole container and checks it (Test archive). Returns problems found; throws when
    /// the container can't be read at all. `progress` gets a fraction from 0 to 1.
    func test(_ file: VFSPath, registry: ProviderRegistry,
              progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String]
    /// Every file that belongs to the container `file` (the volumes of a multi-volume RAR set),
    /// `file` included. Unpack's "Delete archive after unpacking" removes all of them.
    func volumes(of file: VFSPath, registry: ProviderRegistry) async -> [VFSPath]
}

extension ContainerOpener {
    public func test(_ file: VFSPath, registry: ProviderRegistry,
                     progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String] {
        throw VFSError.unsupported("testing \(file.name)")
    }

    public func volumes(of file: VFSPath, registry: ProviderRegistry) async -> [VFSPath] { [file] }
}

extension ProviderRegistry {
    /// The first registered opener that recognises `name`.
    public func containerOpener(forName name: String) -> (any ContainerOpener)? {
        openers.withLock { list in list.first { $0.recognizes(name: name) } }
    }

    /// Whether Enter should open this item as a container.
    public func isContainer(_ item: FileItem) -> Bool {
        if case .file = item.kind { return containerOpener(forName: item.name) != nil }
        return false
    }

    /// Opens `item` as a container and returns the root of its provider, or nil when no opener
    /// reads it. Already opened containers are reused. With `byContent`, every opener is tried.
    public func openContainer(_ item: FileItem, byContent: Bool = false) async throws -> VFSPath? {
        let candidates: [any ContainerOpener] = openers.withLock { list in
            let named = list.filter { $0.recognizes(name: item.name) }
            return byContent ? named + list.filter { !$0.recognizes(name: item.name) } : named
        }
        for opener in candidates {
            let location = ProviderLocation(provider: opener.provider, container: item.path)
            if (try? provider(for: location)) != nil { return VFSPath(location: location, path: "/") }
            if let opened = try await opener.open(item, byContent: byContent, registry: self) {
                register(opened)
                return VFSPath(location: opened.location, path: "/")
            }
        }
        return nil
    }

    /// The opener for a container file: by name, or the one that already opened it (Cmd+PageDown).
    public func containerOpener(forFile file: VFSPath) -> (any ContainerOpener)? {
        if let byName = containerOpener(forName: file.name) { return byName }
        let list = openers.withLock { $0 }
        return list.first { (try? provider(for: ProviderLocation(provider: $0.provider, container: file))) != nil }
    }

    /// Closes the opened containers (archives, file lists) that none of `keeping` is in, directly
    /// or nested. Their index, open files and temporary copies go once nothing else holds the
    /// provider. Opening the file again makes a fresh provider. Returns the closed locations.
    @discardableResult
    public func closeContainers(keeping: some Sequence<ProviderLocation>) -> [ProviderLocation] {
        var kept = Set<ProviderLocation>()
        for location in keeping {
            var next: ProviderLocation? = location
            while let current = next, current.container != nil, kept.insert(current).inserted {
                next = current.container?.location
            }
        }
        return removeProviders { $0.container != nil && !kept.contains($0) }
    }

    /// The opener that made the provider at `location`, if it is a container.
    public func containerOpener(for location: ProviderLocation) -> (any ContainerOpener)? {
        guard location.container != nil else { return nil }
        return openers.withLock { list in list.first { $0.provider == location.provider } }
    }
}
