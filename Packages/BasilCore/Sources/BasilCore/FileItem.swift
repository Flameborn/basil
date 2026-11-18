import Foundation

/// One entry in a directory listing, from any provider.
public struct FileItem: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        case symlink(target: Target)
        case other

        /// What a symlink points to, when known.
        public enum Target: Sendable, Hashable {
            case file, directory, broken, unknown
        }
    }

    public let path: VFSPath
    public let kind: Kind
    /// Logical size in bytes for files; `nil` for directories or when unknown.
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// POSIX permission bits (e.g. 0o755), when the provider has them.
    public let permissions: UInt16?
    public let isHidden: Bool
    /// Provider-specific stable identity (inode/file ID locally), if any.
    public let fileID: UInt64?

    /// The entry name (last path component), stored because sorting and filtering read it constantly.
    public let name: String

    public var id: VFSPath { path }

    public init(path: VFSPath, kind: Kind, size: Int64? = nil, modified: Date? = nil,
                created: Date? = nil, permissions: UInt16? = nil, isHidden: Bool = false,
                fileID: UInt64? = nil) {
        self.path = path
        self.name = path.name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.permissions = permissions
        self.isHidden = isHidden
        self.fileID = fileID
    }

    /// True for directories and symlinks that point to directories.
    public var isDirectoryLike: Bool {
        switch kind {
        case .directory, .symlink(target: .directory): true
        default: false
        }
    }

    /// Total Commander-style split: directories and dot-files without another dot have no extension.
    public var nameAndExtension: (base: String, ext: String) {
        FileItem.splitExtension(name, isDirectory: isDirectoryLike)
    }

    public static func splitExtension(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
