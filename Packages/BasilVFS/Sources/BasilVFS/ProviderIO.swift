import BasilCore
import Foundation

/// Identity and change state of an item, used by the copy engine to detect a source that
/// changed while it was being copied. Fields a provider can't supply are nil and compare equal.
public struct FileFingerprint: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, other }

    public var kind: Kind
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var modifiedNanos: Int64?
    /// Status change time (ctime) in nanoseconds since 1970.
    public var changedNanos: Int64?
    public var fileID: UInt64?
    /// Device or volume the item lives on, when known.
    public var device: Int64?

    public init(kind: Kind, size: Int64, modifiedNanos: Int64? = nil, changedNanos: Int64? = nil,
                fileID: UInt64? = nil, device: Int64? = nil) {
        self.kind = kind
        self.size = size
        self.modifiedNanos = modifiedNanos
        self.changedNanos = changedNanos
        self.fileID = fileID
        self.device = device
    }

    public var description: String {
        "size \(size), mtime \(modifiedNanos.map(String.init) ?? "unknown"), ctime \(changedNanos.map(String.init) ?? "unknown"), id \(fileID.map(String.init) ?? "unknown")"
    }
}

/// Metadata the copy engine carries from source to destination. Providers fill what they have.
public struct FileMetadata: Sendable, Equatable {
    public var permissions: UInt16?
    public var modified: timespec?
    public var created: timespec?
    public var accessed: timespec?
    /// BSD file flags (UF_HIDDEN and so on). Applied after the item is in place.
    public var flags: UInt32?
    /// Extended attributes, including Finder tags and Finder info.
    public var extendedAttributes: [ExtendedAttribute]
    /// Access control list in acl_to_text form.
    public var acl: String?

    public struct ExtendedAttribute: Sendable, Equatable {
        public var name: String
        public var value: Data
        public init(name: String, value: Data) { self.name = name; self.value = value }
    }

    public init(permissions: UInt16? = nil, modified: timespec? = nil, created: timespec? = nil,
                accessed: timespec? = nil, flags: UInt32? = nil,
                extendedAttributes: [ExtendedAttribute] = [], acl: String? = nil) {
        self.permissions = permissions
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.flags = flags
        self.extendedAttributes = extendedAttributes
        self.acl = acl
    }

    public static func == (a: Self, b: Self) -> Bool {
        func eq(_ x: timespec?, _ y: timespec?) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): x.tv_sec == y.tv_sec && x.tv_nsec == y.tv_nsec
            default: false
            }
        }
        return a.permissions == b.permissions && eq(a.modified, b.modified) && eq(a.created, b.created)
            && eq(a.accessed, b.accessed) && a.flags == b.flags
            && a.extendedAttributes == b.extendedAttributes && a.acl == b.acl
    }
}

/// An open file for reading. Reads at explicit offsets, so one handle can serve a pipeline.
public protocol ReadableFile: Sendable {
    /// Reads up to `count` bytes at `offset`. Returns fewer bytes only at end of file.
    func read(at offset: Int64, count: Int) async throws -> Data
    func close() async
}

/// An open file for writing (the copy engine's partial file).
public protocol WritableFile: Sendable {
    var path: VFSPath { get }
    func write(_ data: Data, at offset: Int64) async throws
    func truncate(to length: Int64) async throws
    /// Flushes data and metadata to permanent storage (F_FULLFSYNC locally).
    func synchronize() async throws
    /// Applies metadata except flags (those go on after the file is renamed into place).
    /// Returns warnings for parts that could not be applied.
    func apply(_ metadata: FileMetadata) async throws -> [String]
    func close() async
}

/// Mutating and low-level calls used by operations. Providers without a capability throw
/// `VFSError.unsupported`; operations check `capabilities` before choosing a strategy.
public protocol WritableProvider: FileSystemProvider {
    /// Fingerprint of the item itself (a symlink is not followed).
    func fingerprint(of path: VFSPath) async throws -> FileFingerprint
    func metadata(of path: VFSPath) async throws -> FileMetadata
    /// Applies metadata to an item in place (directories and symlinks, and flags of files).
    func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String]
    /// Opaque identity of the volume holding `path`; equal values mean rename/clone can work between them.
    func volumeIdentifier(of path: VFSPath) async throws -> String?

    func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile
    /// Creates a new file. Fails with `.alreadyExists` if anything is at `path`.
    func createFile(_ path: VFSPath) async throws -> any WritableFile
    /// Renames within this provider. Without `replacing`, fails with `.alreadyExists` if the target exists.
    func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws
    /// Copy-on-write clone of a file (target must not exist). Throws `.unsupported` if the volume can't.
    func clone(_ from: VFSPath, to: VFSPath) async throws
    /// Removes a file, symlink or empty directory.
    func remove(_ path: VFSPath) async throws
    func makeDirectory(_ path: VFSPath) async throws
    /// Flushes an existing file to permanent storage (used after a clone).
    func synchronize(_ path: VFSPath) async throws
    func readSymlink(_ path: VFSPath) async throws -> String
    func createSymlink(_ path: VFSPath, target: String) async throws
    /// Largest chunk the engine should use with this provider, or nil for no limit.
    var maxTransferChunkSize: Int? { get }
}

extension WritableProvider {
    public var maxTransferChunkSize: Int? { nil }
}
