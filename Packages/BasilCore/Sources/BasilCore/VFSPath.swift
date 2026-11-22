import Foundation

/// Identifies a kind of provider ("local", "sftp", "archive", ...).
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let local = ProviderID("local")
}

/// Identifies one mounted provider instance: the provider kind, an instance key
/// (e.g. `user@host:22` for SFTP, empty for local) and, for nested providers
/// such as archives, the path of the container they were opened from.
public struct ProviderLocation: Hashable, Sendable, Codable {
    public let provider: ProviderID
    public let instance: String
    /// The path of the file this provider is opened on (e.g. the zip file).
    /// Stored as an array to allow recursion in a value type; holds 0 or 1 element.
    private let containerStorage: [VFSPath]

    public var container: VFSPath? { containerStorage.first }

    public init(provider: ProviderID, instance: String = "", container: VFSPath? = nil) {
        self.provider = provider
        self.instance = instance
        self.containerStorage = container.map { [$0] } ?? []
    }

    public static let local = ProviderLocation(provider: .local)
}

/// A location in Basil's virtual file system: a provider location plus an
/// absolute POSIX-style path inside it ("/" is the provider root).
///
/// All pane and operation code addresses files through `VFSPath`; only
/// `LocalProvider` converts to and from file-system paths/URLs.
public struct VFSPath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let location: ProviderLocation
    /// Normalised: always starts with "/", never ends with "/" (except root), no "." or "..".
    public let path: String

    public init(location: ProviderLocation, path: String) {
        self.location = location
        self.path = VFSPath.normalise(path)
    }

    public static func local(_ path: String) -> VFSPath {
        VFSPath(location: .local, path: path)
    }

    public var isRoot: Bool { path == "/" }

    /// Path components without the leading root.
    public var components: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Last path component; for a provider root this is "/".
    public var name: String {
        guard !isRoot, let slash = path.lastIndex(of: "/") else { return "/" }
        return String(path[path.index(after: slash)...])
    }

    /// The parent inside the same provider, or `nil` at the provider root.
    /// (Leaving a nested provider's root is a navigation decision: see `container`.)
    public var parent: VFSPath? {
        guard !isRoot, let slash = path.lastIndex(of: "/") else { return nil }
        let parentPath = slash == path.startIndex ? "/" : String(path[..<slash])
        return VFSPath(location: location, normalisedPath: parentPath)
    }

    /// Appends one component. `name` must not contain "/" (it is a single directory entry name).
    public func appending(_ name: String) -> VFSPath {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            return VFSPath(location: location, path: path + "/" + name)
        }
        return VFSPath(location: location, normalisedPath: path == "/" ? "/" + name : path + "/" + name)
    }

    /// Skips normalisation for paths built from already-normalised parts (hot path for listings).
    private init(location: ProviderLocation, normalisedPath: String) {
        self.location = location
        self.path = normalisedPath
    }

    /// The file this path is ultimately stored in: the outermost container (the archive file on
    /// disk) for paths inside nested providers, otherwise the path itself.
    public var outermostContainer: VFSPath {
        location.container?.outermostContainer ?? self
    }

    /// The name to show for this folder: the archive's name at the root of an archive.
    public var displayName: String {
        if isRoot, let container = location.container { return container.name }
        return name
    }

    /// Whether `self` is `other` or lies below it in the same provider location.
    public func hasPrefix(_ other: VFSPath) -> Bool {
        guard location == other.location else { return false }
        if other.isRoot || path == other.path { return true }
        return path.hasPrefix(other.path + "/")
    }

    public var description: String {
        var prefix = ""
        if let container = location.container {
            prefix = container.description + "#"
        } else if location.provider != .local {
            prefix = location.provider.rawValue + "://" + location.instance
        }
        return prefix + path
    }

    static func normalise(_ raw: String) -> String {
        var out: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(part)
            }
        }
        return "/" + out.joined(separator: "/")
    }
}
