import BasilCore
import Foundation
import Synchronization

/// One change to a container's content. Paths inside the container are absolute ("/docs/a.txt").
public enum ContainerChange: Sendable, Equatable {
    /// Adds the file at `source` (any provider) as `at`. An existing entry with that path is replaced.
    case addFile(source: VFSPath, at: String)
    /// Adds a folder entry; its dates and permissions come from `source` when given.
    case addDirectory(source: VFSPath?, at: String)
    /// Adds the symlink at `source` (its target is read from the source provider).
    case addSymlink(source: VFSPath, at: String)
    /// Removes the entry and everything below it.
    case delete(String)
    /// Renames the entry and everything below it.
    case rename(from: String, to: String)

    /// The path this change writes, for adds.
    public var addedPath: String? {
        switch self {
        case .addFile(_, let at), .addDirectory(_, let at), .addSymlink(_, let at): at
        default: nil
        }
    }

    public var source: VFSPath? {
        switch self {
        case .addFile(let s, _), .addSymlink(let s, _): s
        case .addDirectory(let s, _): s
        default: nil
        }
    }
}

/// A format a container writer can create ("zip", "tar.gz", ...).
public struct PackFormat: Sendable, Hashable, Identifiable {
    /// Stable identifier, also the default file extension ("tar.gz").
    public let id: String
    /// Shown in the pack dialog ("ZIP", "tar.gz (gzip)").
    public let name: String
    /// Compresses one file on its own (notes.txt.gz): no folders, one file per archive.
    public let singleFile: Bool
    /// Compression levels the pack dialog offers (empty: the format has none).
    public let levels: [PackLevel]
    /// Whether macOS metadata (extended attributes, Finder tags) can be stored.
    public let storesMacMetadata: Bool

    public init(id: String, name: String, singleFile: Bool = false, levels: [PackLevel] = [.fast, .normal, .maximum],
                storesMacMetadata: Bool = false) {
        self.id = id
        self.name = name
        self.singleFile = singleFile
        self.levels = levels
        self.storesMacMetadata = storesMacMetadata
    }

    public var fileExtension: String { id }
}

/// Compression level in the pack dialog. Each format maps it to its own scale.
public enum PackLevel: String, Sendable, Codable, CaseIterable {
    case store, fast, normal, maximum

    public var title: String {
        switch self {
        case .store: "Store (no compression)"
        case .fast: "Fast"
        case .normal: "Normal"
        case .maximum: "Maximum"
        }
    }
}

public struct PackOptions: Sendable, Equatable {
    public var format: String
    public var level: PackLevel
    /// Store extended attributes, Finder tags and resource forks (AppleDouble, like Finder).
    public var macMetadata: Bool

    public init(format: String, level: PackLevel = .normal, macMetadata: Bool = true) {
        self.format = format
        self.level = level
        self.macMetadata = macMetadata
    }
}

/// How a container writer talks to whoever runs it (a queue operation, or a test).
public protocol ContainerWriteMonitor: Sendable {
    /// Waits while paused; throws CancellationError when cancelled.
    func checkpoint() async throws
    func log(_ message: String)
    /// Source bytes newly written, for progress.
    func written(bytes: Int64)
    /// Reading a source failed before any of it was written. True skips it, false tries again;
    /// throwing stops the whole write (nothing is changed).
    func skipAfterError(_ error: any Error, at source: VFSPath) async throws -> Bool
}

extension ContainerWriteMonitor {
    public func skipAfterError(_ error: any Error, at source: VFSPath) async throws -> Bool { throw error }
}

public struct ContainerWriteResult: Sendable {
    /// Entries in the finished container.
    public var entries = 0
    /// Sources that changed while they were read: their entry holds what was read. Callers
    /// write again (the retry policy) or accept them.
    public var changedSources: [VFSPath] = []
    /// Sources left out after an error.
    public var skipped: [VFSPath] = []
    /// Notes for the log (for example metadata that could not be read).
    public var warnings: [String] = []

    public init() {}
}

/// Writes containers: creates new archives and changes existing ones. Archive writers register
/// in `ProviderRegistry`; queue operations only talk to the registry.
///
/// Both calls are all or nothing: the new container is written next to the target under a
/// temporary name, synchronised, read back and checked, then renamed into place.
public protocol ContainerWriter: Sendable {
    /// Formats `create` can write, in pack dialog order.
    var packFormats: [PackFormat] { get }
    /// Creates a new container at `destination`, which must be a local path that does not exist
    /// (or is replaced when `replacing`).
    func create(_ destination: VFSPath, options: PackOptions, changes: [ContainerChange], replacing: Bool,
                registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult
    /// Whether `container` (a file this writer's provider opened) can be changed. Nil when it
    /// can; otherwise the reason it can't ("archives inside archives cannot be changed yet").
    func updateRefusal(for container: VFSPath, registry: ProviderRegistry) -> String?
    /// Rewrites `container` with `changes` applied.
    func update(_ container: VFSPath, changes: [ContainerChange], macMetadata: Bool,
                registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult
}

extension ProviderRegistry {
    /// Adds a writer. Writers registered earlier are asked first for a format.
    public func register(writer: any ContainerWriter) {
        writers.withLock { $0.append(writer) }
    }

    /// Every format any writer creates, without duplicates, in registration order.
    public var packFormats: [PackFormat] {
        var seen = Set<String>()
        return writers.withLock { $0 }.flatMap(\.packFormats).filter { seen.insert($0.id).inserted }
    }

    /// The writer that creates `format`.
    public func containerWriter(forFormat format: String) -> (any ContainerWriter)? {
        writers.withLock { $0 }.first { $0.packFormats.contains { $0.id == format } }
    }

    /// The writer that changes containers shown by the provider at `location`, if any.
    public func containerWriter(for location: ProviderLocation) -> (any ContainerWriter)? {
        guard location.container != nil, let opener = containerOpener(for: location) else { return nil }
        return opener as? any ContainerWriter
    }
}

extension ContainerChange {
    /// The adds for `source` (a file, symlink or whole folder) placed at `at` inside a container.
    /// Without `paths`, files from subfolders are stored by name only (no folder entries); a later
    /// file with a name already used is left out and reported in `duplicates`.
    public static func adds(for source: VFSPath, at: String, paths: Bool = true, registry: ProviderRegistry,
                            duplicates: inout [VFSPath], used: inout Set<String>) async throws -> [ContainerChange] {
        let provider = try registry.provider(for: source.location)
        let item = try await provider.item(at: source)
        switch item.kind {
        case .directory:
            var result: [ContainerChange] = []
            if paths {
                result.append(.addDirectory(source: source, at: at))
                used.insert(at)
            }
            var children: [FileItem] = []
            for try await batch in provider.list(source) { children += batch }
            for child in children {
                let childAt = paths ? (at == "/" ? "/" : at + "/") + child.name : "/" + child.name
                result += try await adds(for: child.path, at: childAt, paths: paths, registry: registry,
                                         duplicates: &duplicates, used: &used)
            }
            return result
        case .symlink:
            guard used.insert(at).inserted else { duplicates.append(source); return [] }
            return [.addSymlink(source: source, at: at)]
        case .file:
            guard used.insert(at).inserted else { duplicates.append(source); return [] }
            return [.addFile(source: source, at: at)]
        case .other:
            return []
        }
    }
}
