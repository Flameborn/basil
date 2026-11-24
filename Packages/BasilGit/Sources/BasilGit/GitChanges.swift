import Foundation

/// Staging, committing and the last commit's message: what the Commit window does. These only
/// change git's own database (the index and the object store), never the user's files, so they
/// run at once instead of in the queue (user's decision, 2026-11-24).
extension GitService {
    static func pathspecs(_ paths: [String]) -> [String] { paths.map { ":(literal)" + $0 } }

    /// `git add -A` for the given paths (relative to the root): new, changed and deleted files.
    public func stage(_ paths: [String], root: String) async throws {
        guard !paths.isEmpty else { return }
        try await run(["add", "-A", "--"] + Self.pathspecs(paths), in: root)
    }

    /// Takes the given paths out of the index again (back to the last commit's version there).
    /// Before the first commit there is nothing to go back to, so they are removed from the
    /// index; the files stay.
    public func unstage(_ paths: [String], root: String, hasCommit: Bool) async throws {
        guard !paths.isEmpty else { return }
        if hasCommit {
            try await run(["restore", "--staged", "--"] + Self.pathspecs(paths), in: root)
        } else {
            try await run(["rm", "--cached", "-r", "-q", "--"] + Self.pathspecs(paths), in: root)
        }
    }

    /// Commits what is staged with `message` (passed on stdin, never on argv). With `amend` the
    /// last commit is replaced.
    public func commit(message: String, amend: Bool, root: String) async throws {
        var arguments = ["commit", "-q", "--cleanup=strip", "-F", "-"]
        if amend { arguments.append("--amend") }
        try await run(arguments, in: root, input: Data(message.utf8))
    }

    /// The full message of the last commit, or nil before the first one.
    public func lastCommitMessage(root: String) async -> String? {
        guard let output = try? await output(["log", "-1", "--format=%B"], in: root), output.succeeded else { return nil }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The changes of one file against the last commit, staged and not: `git diff HEAD`.
    /// Files the last commit does not have (untracked, newly added, or no commit yet) are shown
    /// whole as added lines.
    public func diff(of entry: GitStatus.Entry, root: String, hasCommit: Bool) async throws -> GitDiff {
        let common = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3"]
        let newInIndex: Bool = switch entry.change {
        case .untracked, .ignored: true
        case .changed(let index, _): index == "A"
        case .renamed, .conflict: false
        }
        if !hasCommit || newInIndex {
            if entry.isFolder { return GitDiff(lines: [], isBinary: false, note: "\(entry.path) is a folder") }
            // --no-index ends with status 1 when there are differences.
            let output = try await output(common + ["--no-index", "--", "/dev/null", entry.path], in: root)
            guard output.status <= 1 else { throw GitError(output.message) }
            return GitDiff.parse(output.text)
        }
        var paths = [entry.path]
        if case .renamed(let from, _, _) = entry.change { paths.insert(from, at: 0) }
        return GitDiff.parse(String(decoding: try await run(common + ["-M", "HEAD", "--"] + Self.pathspecs(paths), in: root),
                                    as: UTF8.self))
    }
}

/// A unified diff as lines for the Commit window.
public struct GitDiff: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// "@@ -10,7 +10,8 @@": where the next lines are.
        case hunk = "Changes"
        case same = "Same"
        case added = "Added"
        case removed = "Removed"
        /// "No newline at end of file" and similar.
        case note = "Note"
    }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var oldLine: Int?
        public var newLine: Int?
        public var text: String
    }

    public var lines: [Line]
    public var isBinary: Bool
    /// Shown instead of lines (a binary file, a folder, no changes).
    public var note: String?

    public init(lines: [Line], isBinary: Bool, note: String? = nil) {
        self.lines = lines
        self.isBinary = isBinary
        self.note = note
    }

    public static func parse(_ text: String) -> GitDiff {
        var lines: [Line] = []
        var binary = false
        var old = 0, new = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                // @@ -a[,b] +c[,d] @@ context
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                lines.append(Line(kind: .hunk, oldLine: old, newLine: new, text: line))
                continue
            }
            if !inHunk || line.hasPrefix("diff --git ") {
                inHunk = false
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true }
                continue
            }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case " ":
                lines.append(Line(kind: .same, oldLine: old, newLine: new, text: body))
                old += 1; new += 1
            case "-":
                lines.append(Line(kind: .removed, oldLine: old, newLine: nil, text: body))
                old += 1
            case "+":
                lines.append(Line(kind: .added, oldLine: nil, newLine: new, text: body))
                new += 1
            case "\\":
                lines.append(Line(kind: .note, oldLine: nil, newLine: nil, text: body.trimmingCharacters(in: .whitespaces)))
            default:
                inHunk = false
            }
        }
        let note: String? = binary ? "Binary file, no line differences" : (lines.isEmpty ? "No changes" : nil)
        return GitDiff(lines: lines, isBinary: binary, note: note)
    }

    /// What VoiceOver reads for a line: "Added, line 12: let x = 2".
    public static func spoken(_ line: Line) -> String {
        let content = line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : line.text
        switch line.kind {
        case .hunk:
            return "Changes at line \(line.newLine ?? line.oldLine ?? 0)"
        case .note:
            return "Note: \(line.text)"
        case .removed:
            return "Removed, line \(line.oldLine ?? 0): \(content)"
        case .added:
            return "Added, line \(line.newLine ?? 0): \(content)"
        case .same:
            return "Same, line \(line.newLine ?? 0): \(content)"
        }
    }
}

extension GitStatus.Entry {
    /// Whether everything of this entry is staged, nothing, or some of it.
    public enum Staging: Sendable, Equatable { case staged, notStaged, partly }

    public var staging: Staging {
        switch change {
        case .untracked, .ignored: return .notStaged
        case .conflict: return .notStaged
        case .changed(let index, let worktree), .renamed(_, let index, let worktree):
            if index == "." { return .notStaged }
            return worktree == "." ? .staged : .partly
        }
    }

    /// The paths a stage or unstage of this entry must name (a rename names both).
    public var paths: [String] {
        if case .renamed(let from, _, _) = change { return [from, path] }
        return [path]
    }
}
