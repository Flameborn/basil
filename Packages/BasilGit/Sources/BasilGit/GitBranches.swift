import Foundation

/// A local or remote branch, from `git for-each-ref`.
public struct GitBranch: Sendable, Equatable, Identifiable {
    /// "main", or "origin/feature" for a remote branch.
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var commit: String
    public var subject: String
    public var date: Date?
    /// The branch it tracks ("origin/main") and how far apart they are.
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// The upstream is configured but gone on the server.
    public var upstreamGone = false

    public var id: String { (isRemote ? "remote:" : "local:") + name }

    /// "origin/feature" -> "feature": the local branch a checkout creates.
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

extension GitService {
    static let branchFormat = ["%(refname)", "%(refname:short)", "%(objectname:short)", "%(upstream:short)",
                               "%(upstream:track)", "%(HEAD)", "%(committerdate:unix)", "%(contents:subject)"]
        .joined(separator: "%00")

    /// Local branches, then remote ones (without the remotes' HEAD links), each sorted by name.
    public func branches(root: String) async throws -> [GitBranch] {
        let data = try await run(["for-each-ref", "--format=" + Self.branchFormat, "refs/heads", "refs/remotes"], in: root)
        return Self.parseBranches(String(decoding: data, as: UTF8.self))
    }

    static func parseBranches(_ text: String) -> [GitBranch] {
        var local: [GitBranch] = [], remote: [GitBranch] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8 else { continue }
            let isRemote = f[0].hasPrefix("refs/remotes/")
            // origin/HEAD points at another remote branch; it is not one of its own.
            if isRemote, f[0].hasSuffix("/HEAD") { continue }
            var branch = GitBranch(name: f[1], isRemote: isRemote, isCurrent: f[5] == "*", commit: f[2],
                                   subject: f[7...].joined(separator: " "),
                                   date: Double(f[6]).map { Date(timeIntervalSince1970: $0) },
                                   upstream: f[3].isEmpty ? nil : f[3])
            // [ahead 2, behind 1], [gone]
            let track = f[4]
            branch.upstreamGone = track.contains("gone")
            if let r = track.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                branch.ahead = Int(track[r].split(separator: " ")[1]) ?? 0
            }
            if let r = track.range(of: #"behind (\d+)"#, options: .regularExpression) {
                branch.behind = Int(track[r].split(separator: " ")[1]) ?? 0
            }
            if isRemote { remote.append(branch) } else { local.append(branch) }
        }
        let byName: (GitBranch, GitBranch) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return local.sorted(by: byName) + remote.sorted(by: byName)
    }

    /// Creates a branch at the current commit; with `switchTo` also switches to it (the working
    /// tree stays as it is either way).
    public func createBranch(_ name: String, switchTo: Bool, root: String) async throws {
        try await run(switchTo ? ["switch", "-c", name] : ["branch", "--", name], in: root)
    }

    public func renameBranch(_ name: String, to newName: String, root: String) async throws {
        try await run(["branch", "-m", "--", name, newName], in: root)
    }

    /// Deletes a local branch. Without `force` git refuses one whose commits are not merged
    /// (`GitError.isNotMerged`).
    public func deleteBranch(_ name: String, force: Bool, root: String) async throws {
        try await run(["branch", force ? "-D" : "-d", "--", name], in: root)
    }

    /// Whether `name` is a valid branch name (`git check-ref-format --branch`).
    public func isValidBranchName(_ name: String, root: String) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return (try? await output(["check-ref-format", "--branch", name], in: root))?.succeeded ?? false
    }
}

extension GitService {
    /// The branch HEAD is on, or nil when detached.
    public func currentBranch(root: String) async -> String? {
        guard let output = try? await output(["symbolic-ref", "--short", "-q", "HEAD"], in: root), output.succeeded else { return nil }
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The upstream of the current branch ("origin/main"), or nil when it has none.
    public func upstream(root: String) async -> String? {
        guard let output = try? await output(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root),
              output.succeeded else { return nil }
        let name = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The repository's remotes, by name.
    public func remotes(root: String) async throws -> [String] {
        String(decoding: try await run(["remote"], in: root), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Adds a remote (only git's configuration changes).
    public func addRemote(_ name: String, url: String, root: String) async throws {
        try await run(["remote", "add", "--", name, url], in: root)
    }
}

extension GitError {
    /// `git branch -d` refused a branch whose commits are not merged.
    public var isNotMerged: Bool { message.contains("not fully merged") }
}
