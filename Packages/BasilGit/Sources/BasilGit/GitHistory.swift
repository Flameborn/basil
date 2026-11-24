import Foundation

/// One commit of `git log`.
public struct GitCommit: Sendable, Equatable, Identifiable {
    public var hash: String
    public var shortHash: String
    public var parents: [String]
    public var author: String
    public var email: String
    public var date: Date
    public var subject: String
    /// The whole message (subject and body).
    public var message: String
    public var id: String { hash }
}

/// A file changed by a commit (against its first parent).
public struct GitCommitFile: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case added, modified, deleted, typeChanged
        case renamed(from: String)
        case copied(from: String)
    }
    public var path: String
    public var change: Change

    public var text: String {
        switch change {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .typeChanged: "Type changed"
        case .renamed(let from): "Renamed from \(from)"
        case .copied(let from): "Copied from \(from)"
        }
    }
}

/// One line of `git blame`.
public struct GitBlameLine: Sendable, Equatable {
    public var line: Int
    public var text: String
    public var shortHash: String
    public var author: String
    public var date: Date?
    public var summary: String
    /// The line is changed in the working tree, not committed yet.
    public var isUncommitted: Bool
}

extension GitService {
    /// The newest `limit` commits of the current branch, or of one file (following renames).
    public func log(root: String, path: String? = nil, limit: Int = 1000) async throws -> [GitCommit] {
        var arguments = ["log", "-z", "-n", String(limit), "--format=%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%B"]
        if let path { arguments += ["--follow", "--", ":(literal)" + path] }
        let output = try await output(arguments, in: root)
        // A repository without commits has no log.
        if !output.succeeded, output.stderr.contains("does not have any commits") { return [] }
        guard output.succeeded else { throw GitError(output.message) }
        return Self.parseLog(output.text)
    }

    static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\0").compactMap { record in
            let f = record.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8, let time = Double(f[5]) else { return nil }
            return GitCommit(hash: f[0].trimmingCharacters(in: .whitespacesAndNewlines), shortHash: f[1],
                             parents: f[2].split(separator: " ").map(String.init), author: f[3], email: f[4],
                             date: Date(timeIntervalSince1970: time), subject: f[6],
                             message: f[7].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The files `commit` changed against its first parent (everything for the first commit).
    public func files(of commit: GitCommit, root: String) async throws -> [GitCommitFile] {
        var arguments = ["diff-tree", "-r", "-M", "-z", "--name-status", "--no-commit-id"]
        if let parent = commit.parents.first { arguments += [parent, commit.hash] } else { arguments += ["--root", commit.hash] }
        return Self.parseNameStatus(String(decoding: try await run(arguments, in: root), as: UTF8.self))
    }

    static func parseNameStatus(_ text: String) -> [GitCommitFile] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var files: [GitCommitFile] = []
        while let status = fields.popFirst(), let first = status.first {
            guard let path = fields.popFirst() else { break }
            switch first {
            case "R", "C":
                guard let to = fields.popFirst() else { break }
                files.append(GitCommitFile(path: to, change: first == "R" ? .renamed(from: path) : .copied(from: path)))
            case "A": files.append(GitCommitFile(path: path, change: .added))
            case "D": files.append(GitCommitFile(path: path, change: .deleted))
            case "T": files.append(GitCommitFile(path: path, change: .typeChanged))
            default: files.append(GitCommitFile(path: path, change: .modified))
            }
        }
        return files
    }

    /// What `commit` changed in one file, against its first parent.
    public func diff(of file: GitCommitFile, in commit: GitCommit, root: String) async throws -> GitDiff {
        var paths = [file.path]
        if case .renamed(let from) = file.change { paths.insert(from, at: 0) }
        if case .copied(let from) = file.change { paths.insert(from, at: 0) }
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3", "-M"]
        if let parent = commit.parents.first {
            arguments += [parent, commit.hash]
        } else {
            // The first commit: against the empty tree.
            arguments += ["4b825dc642cb6eb9a060e54bf8d69288fbee4904", commit.hash]
        }
        arguments += ["--"] + Self.pathspecs(paths)
        return GitDiff.parse(String(decoding: try await run(arguments, in: root), as: UTF8.self))
    }

    /// Who last changed each line of a file, as the working tree has it (lines not committed
    /// yet say so).
    public func blame(_ path: String, root: String) async throws -> [GitBlameLine] {
        let data = try await run(["blame", "--line-porcelain", "--", path], in: root)
        return Self.parseBlame(String(decoding: data, as: UTF8.self))
    }

    static func parseBlame(_ text: String) -> [GitBlameLine] {
        var lines: [GitBlameLine] = []
        var hash = "", author = "", summary = "", line = 0
        var time: Double?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                let uncommitted = hash.allSatisfy { $0 == "0" }
                lines.append(GitBlameLine(line: line, text: String(raw.dropFirst()), shortHash: String(hash.prefix(7)),
                                          author: uncommitted ? "Not committed yet" : author,
                                          date: uncommitted ? nil : time.map { Date(timeIntervalSince1970: $0) },
                                          summary: uncommitted ? "" : summary, isUncommitted: uncommitted))
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                hash = key
                // <hash> <original line> <final line> [<group size>]
                line = Int(value.split(separator: " ").dropFirst().first ?? "") ?? line
            } else if key == "author" {
                author = value
            } else if key == "author-time" {
                time = Double(value)
            } else if key == "summary" {
                summary = value
            }
        }
        return lines
    }
}
