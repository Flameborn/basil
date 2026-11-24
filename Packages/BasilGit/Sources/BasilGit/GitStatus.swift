import Foundation

/// The state of a repository's working tree, from `git status --porcelain=v2 -z --branch`.
/// Paths are relative to the repository root, with "/" and no trailing slash.
public struct GitStatus: Sendable, Equatable {
    public struct Branch: Sendable, Equatable {
        /// The branch name; nil when HEAD is detached.
        public var head: String?
        /// The commit HEAD points at; nil before the first commit.
        public var commit: String?
        public var upstream: String?
        public var ahead = 0
        public var behind = 0

        public init(head: String? = nil, commit: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
            self.head = head
            self.commit = commit
            self.upstream = upstream
            self.ahead = ahead
            self.behind = behind
        }
    }

    public enum Change: Sendable, Equatable {
        /// A tracked file (or submodule) with changes. `index` and `worktree` are git's XY
        /// letters ("M", "A", "D", "R", "C", "T"), "." for none.
        case changed(index: Character, worktree: Character)
        /// Renamed or copied in the index (`from` is the old path).
        case renamed(from: String, index: Character, worktree: Character)
        /// A merge conflict.
        case conflict
        case untracked
        case ignored
    }

    public struct Entry: Sendable, Equatable {
        public var path: String
        public var change: Change
        /// Untracked and ignored folders are reported as one entry ("build/").
        public var isFolder: Bool
    }

    public var branch = Branch()
    public var entries: [Entry] = []

    public init(branch: Branch = Branch(), entries: [Entry] = []) {
        self.branch = branch
        self.entries = entries
    }

    /// Parses NUL-separated porcelain v2 output.
    public static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus()
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        while let line = fields.popFirst() {
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.branch.commit = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": status.branch.head = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.branch.upstream = parts[2]
                case "branch.ab":
                    for value in parts[2].split(separator: " ") {
                        if value.hasPrefix("+") { status.branch.ahead = Int(value.dropFirst()) ?? 0 }
                        if value.hasPrefix("-") { status.branch.behind = Int(value.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                status.entries.append(Entry(path: String(parts[8]), change: .changed(index: xy[0], worktree: xy[1]), isFolder: false))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let from = fields.popFirst() ?? ""
                guard parts.count == 10 else { continue }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                status.entries.append(Entry(path: String(parts[9]), change: .renamed(from: from, index: xy[0], worktree: xy[1]),
                                            isFolder: false))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.entries.append(Entry(path: String(parts[10]), change: .conflict, isFolder: false))
            case "?", "!":
                var path = String(line.dropFirst(2))
                let folder = path.hasSuffix("/")
                if folder { path.removeLast() }
                status.entries.append(Entry(path: path, change: kind == "?" ? .untracked : .ignored, isFolder: folder))
            default:
                continue
            }
        }
        return status
    }

    /// What the Git column shows for the items of one folder.
    public struct FolderColumn: Sendable, Equatable {
        /// Text by item name; clean items are left out.
        public var byName: [String: String] = [:]
        /// Inside an untracked or ignored folder every item is the same: "Untracked" or "Ignored".
        public var everything: String?

        public init(byName: [String: String] = [:], everything: String? = nil) {
            self.byName = byName
            self.everything = everything
        }

        public func text(for name: String) -> String? { everything ?? byName[name] }
    }

    /// The Git column for the items of `folder` (relative to the root, "" for the root).
    /// A folder with changes somewhere inside reads "Changes".
    public func column(forFolder folder: String) -> FolderColumn {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var column = FolderColumn()
        var changedFolders: Set<String> = []
        for entry in entries {
            guard entry.path.hasPrefix(prefix) else {
                if entry.isFolder, prefix.hasPrefix(entry.path + "/"), entry.change == .untracked || entry.change == .ignored {
                    return FolderColumn(everything: Self.text(for: entry.change))
                }
                continue
            }
            let rest = entry.path.dropFirst(prefix.count)
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                if entry.change != .ignored { changedFolders.insert(String(rest[..<slash])) }
            } else {
                column.byName[String(rest)] = Self.text(for: entry.change)
            }
        }
        for name in changedFolders where column.byName[name] == nil { column.byName[name] = "Changes" }
        return column
    }

    /// "Modified", "Staged", "Untracked", ... for one entry.
    public static func text(for change: Change) -> String {
        switch change {
        case .conflict: return "Conflict"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .renamed(_, _, let worktree):
            return worktree == "." ? "Renamed" : "Renamed, modified"
        case .changed(let index, let worktree):
            switch (index, worktree) {
            case ("A", "."): return "Added"
            case ("A", _): return "Added, modified"
            case ("D", _): return "Deleted"
            case (".", "D"): return "Deleted"
            case (".", "T"): return "Type changed"
            case (".", _): return "Modified"
            case (_, "."): return "Staged"
            default: return "Staged, modified"
            }
        }
    }
}
