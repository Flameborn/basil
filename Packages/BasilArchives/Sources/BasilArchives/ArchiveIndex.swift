import BasilCore
import Foundation

/// The folder tree of an archive, built once from its entry list. Folders that only appear as
/// part of a path ("a/b/c.txt" without "a/") are added. A later entry with the same path
/// replaces an earlier one (tar files appended to), and an entry under a file path makes it a folder.
struct ArchiveIndex: Sendable {
    /// Entries by normalised path. Folders added for paths have ordinal -1.
    private(set) var entries: [String: ArchiveEntry] = [:]
    /// Child names of each folder, in archive order.
    private(set) var children: [String: [String]] = ["/": []]

    /// Every entry as the backend listed it, in archive order (read sessions need it).
    let list: [ArchiveEntry]

    var count: Int { entries.count }

    init(_ list: [ArchiveEntry]) {
        self.list = list
        for entry in list where entry.path != "/" {
            add(entry)
        }
    }

    func entry(_ path: String) -> ArchiveEntry? {
        path == "/" ? ArchiveIndex.root : entries[path]
    }

    static let root = ArchiveEntry(path: "/", kind: .directory, ordinal: -1)

    private mutating func add(_ entry: ArchiveEntry) {
        ensureFolder(Self.parent(of: entry.path))
        if let existing = entries[entry.path] {
            // An explicit folder entry after implicit children keeps the children.
            if existing.kind == .directory, entry.kind != .directory, children[entry.path]?.isEmpty == false { return }
            entries[entry.path] = entry
        } else {
            entries[entry.path] = entry
            children[Self.parent(of: entry.path), default: []].append(Self.name(of: entry.path))
        }
        if entry.kind == .directory, children[entry.path] == nil { children[entry.path] = [] }
    }

    private mutating func ensureFolder(_ path: String) {
        guard path != "/" else { return }
        if let existing = entries[path] {
            if existing.kind != .directory {
                entries[path] = ArchiveEntry(path: path, kind: .directory, modified: existing.modified, ordinal: -1)
            }
            if children[path] == nil { children[path] = [] }
            return
        }
        ensureFolder(Self.parent(of: path))
        entries[path] = ArchiveEntry(path: path, kind: .directory, ordinal: -1)
        children[path] = []
        children[Self.parent(of: path), default: []].append(Self.name(of: path))
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Resolves a symlink target inside the archive, for the item kind ("folder link").
    func symlinkTargetKind(of entry: ArchiveEntry) -> FileItem.Kind.Target {
        guard let target = entry.symlinkTarget, !target.hasPrefix("/") else { return .unknown }
        let resolved = VFSPath.local(Self.parent(of: entry.path) + "/" + target).path
        switch self.entry(resolved)?.kind {
        case .directory: return .directory
        case .file: return .file
        case nil: return .broken
        default: return .unknown
        }
    }
}
