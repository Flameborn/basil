// BasilArchives: archives as folders. Backends (libarchive now, 7-Zip and UnRAR later) read
// archive files; ArchiveProvider shows one archive as a read-only folder tree; ArchiveOpener
// plugs both into ProviderRegistry as a ContainerOpener.
import BasilCore
import BasilVFS
import Foundation

/// One entry of an archive as a backend reports it, in archive order.
public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, other }

    /// Normalised absolute path inside the archive ("/folder/file.txt").
    public var path: String
    public var kind: Kind
    public var size: Int64?
    public var modified: timespec?
    public var permissions: UInt16?
    public var symlinkTarget: String?
    public var isEncrypted: Bool
    /// Position of the entry in the archive (0 for the first header). Backends use it to find the data.
    public var ordinal: Int
    /// The entry whose data this entry has (a tar hard link points to an earlier entry); usually `ordinal`.
    public var dataOrdinal: Int
    /// AppleDouble data with the entry's extended attributes (Finder tags, resource fork), if stored.
    public var macMetadata: Data?

    public init(path: String, kind: Kind, size: Int64? = nil, modified: timespec? = nil,
                permissions: UInt16? = nil, symlinkTarget: String? = nil, isEncrypted: Bool = false,
                ordinal: Int, dataOrdinal: Int? = nil, macMetadata: Data? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.symlinkTarget = symlinkTarget
        self.isEncrypted = isEncrypted
        self.ordinal = ordinal
        self.dataOrdinal = dataOrdinal ?? ordinal
        self.macMetadata = macMetadata
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.path == b.path && a.kind == b.kind && a.size == b.size && a.permissions == b.permissions
            && a.symlinkTarget == b.symlinkTarget && a.isEncrypted == b.isEncrypted
            && a.ordinal == b.ordinal && a.dataOrdinal == b.dataOrdinal
            && a.modified?.tv_sec == b.modified?.tv_sec && a.modified?.tv_nsec == b.modified?.tv_nsec
    }
}

/// Reads entry data. Used from one thread at a time (the provider's own queue); calls block.
public protocol ArchiveReadSession: AnyObject {
    /// Reads up to `count` bytes of `entry`'s data at `offset`. Fewer bytes only at the end.
    func read(_ entry: ArchiveEntry, at offset: Int64, count: Int) throws -> Data
}

/// A library or tool that reads archive files. All calls block; callers run them off the
/// cooperative pool. Several backends can be registered in `ArchiveOpener`; the first one that
/// reads a file wins, so dedicated backends (7-Zip, UnRAR) go ahead of libarchive.
public protocol ArchiveBackend: Sendable {
    /// Shown in logs ("libarchive").
    var name: String { get }
    /// Whether a file with this name is an archive this backend reads (Enter opens it).
    func recognizes(name: String) -> Bool
    /// Lists the entries of the local file `url`, in archive order. Returns nil when the file
    /// is not a format this backend reads. `byContent` allows any name (Cmd+PageDown).
    func entries(of url: URL, byContent: Bool) throws -> [ArchiveEntry]?
    /// Opens a session for reading entry data of `url`, opened earlier with the same `byContent`.
    func session(for url: URL, byContent: Bool) -> any ArchiveReadSession
    /// Reads every entry's data and reports problems (bad checksums, damaged data).
    /// `progress` gets the fraction done and the entry name; when it returns false, stop with CancellationError.
    func test(_ url: URL, byContent: Bool, progress: (Double, String) -> Bool) throws -> [String]
}

public enum ArchiveError: Error, Sendable, Equatable {
    /// The library reported an error for the archive or an entry.
    case damaged(String, archive: String)
    case encrypted(entry: String)
    case entryNotFound(String)
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .damaged(let message, let archive): "\(archive): \(message)"
        case .encrypted(let entry): "\(entry) is encrypted. Encrypted archives are not supported yet."
        case .entryNotFound(let entry): "\(entry) is no longer in the archive"
        }
    }
}

/// Splits a name into lowercased suffixes for archive recognition: "a.Tar.GZ" -> ["gz", "tar.gz"].
enum ArchiveNames {
    static func suffixes(of name: String) -> [String] {
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, !parts[0].isEmpty || parts.count > 2 else { return [] }
        var result: [String] = []
        if let last = parts.last { result.append(String(last)) }
        if parts.count > 2 { result.append(parts.suffix(2).joined(separator: ".")) }
        return result
    }
}
