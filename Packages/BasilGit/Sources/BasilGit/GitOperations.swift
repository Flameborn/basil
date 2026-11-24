import BasilCore
import BasilOperations
import BasilVFS
import Foundation

extension OperationKind {
    public static let gitDiscard: OperationKind = "gitdiscard"
    public static let gitPush: OperationKind = "gitpush"
    public static let gitPull: OperationKind = "gitpull"
    public static let gitFetch: OperationKind = "gitfetch"
}

/// The Git operation kinds for Settings > Sounds and Speech; registered at launch like a plugin's.
@MainActor
public enum GitOperationKinds {
    public static func register() {
        OperationKindCatalog.register(OperationKindInfo(kind: .gitDiscard, name: "Discard Git Changes", pastTense: "discarded"))
        OperationKindCatalog.register(OperationKindInfo(kind: .gitPull, name: "Git Pull", pastTense: "pulled"))
        OperationKindCatalog.register(OperationKindInfo(kind: .gitPush, name: "Git Push", pastTense: "pushed"))
        OperationKindCatalog.register(OperationKindInfo(kind: .gitFetch, name: "Git Fetch", pastTense: "fetched"))
        OperationKindCatalog.register(OperationKindInfo(kind: .gitCheckout, name: "Git Checkout", pastTense: "checked out"))
        OperationKindCatalog.register(OperationKindInfo(kind: .gitMerge, name: "Git Merge", pastTense: "merged"))
    }
}

/// Commit window, Discard Changes: puts files back to the last commit's version. Files the last
/// commit does not have (untracked, newly added, the new name of a rename) go to the Trash
/// instead of being deleted, after leaving the index. It changes the user's files, so it is a
/// queue item.
public struct DiscardChangesOperation: QueueOperation {
    public let root: String
    public let entries: [GitStatus.Entry]
    public let hasCommit: Bool
    let git: GitService
    /// Moves a file to the Trash (the local provider's; tests record instead).
    let trash: @Sendable (VFSPath) async throws -> Void

    public init(entries: [GitStatus.Entry], root: String, hasCommit: Bool, git: GitService, registry: ProviderRegistry) {
        self.init(entries: entries, root: root, hasCommit: hasCommit, git: git) { path in
            try await registry.writableProvider(for: path.location).trash(path)
        }
    }

    init(entries: [GitStatus.Entry], root: String, hasCommit: Bool, git: GitService,
         trash: @escaping @Sendable (VFSPath) async throws -> Void) {
        self.entries = entries
        self.root = root
        self.hasCommit = hasCommit
        self.git = git
        self.trash = trash
    }

    public var kind: OperationKind { .gitDiscard }
    public var title: String {
        "Discard changes to \(entries.count == 1 ? (entries[0].path as NSString).lastPathComponent : "\(entries.count) files")"
    }

    public func run(_ context: OperationContext) async throws {
        var restore: [String] = []
        var remove: [String] = []
        for entry in entries {
            switch entry.change {
            case .untracked, .ignored:
                remove.append(entry.path)
            case .changed(let index, _) where index == "A" || !hasCommit:
                remove.append(entry.path)
            case .renamed(let from, _, _):
                restore.append(from)
                remove.append(entry.path)
            case .changed, .conflict:
                if hasCommit { restore.append(entry.path) } else { remove.append(entry.path) }
            }
        }
        context.items(done: 0, total: entries.count)
        try await context.checkpoint()
        if !restore.isEmpty {
            context.progress(nil, "Restoring \(restore.count == 1 ? restore[0] : "\(restore.count) files")")
            try await git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + GitService.pathspecs(restore), in: root)
            for path in restore { context.log("Restored \(path) from the last commit") }
        }
        for (index, path) in remove.enumerated() {
            try await context.checkpoint()
            context.progress(Double(index) / Double(max(1, remove.count)), path)
            // Leaves the index first (quietly does nothing for an untracked file).
            _ = try? await git.output(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + GitService.pathspecs([path]), in: root)
            let file = VFSPath.local((root as NSString).appendingPathComponent(path))
            if FileManager.default.fileExists(atPath: file.path) {
                try await trash(file)
                context.log("Moved \(path) to the Trash")
            }
        }
        context.items(done: entries.count, total: entries.count)
        context.progress(1, "Discarded")
    }
}

/// Pull, push or fetch for the repository at `root`, as a queue item. Logins are asked through
/// `login` (GIT_ASKPASS). Cancelling stops git. git's own messages go into the item's log.
public struct GitRemoteOperation: QueueOperation {
    public enum Action: String, Sendable {
        case pull, push, fetch

        var arguments: [String] {
            switch self {
            // The user's own pull settings (merge or rebase) apply; never an editor.
            case .pull: ["pull", "--no-edit"]
            case .push: ["push"]
            case .fetch: ["fetch", "--prune"]
            }
        }

        var verb: String { rawValue.capitalized }
    }

    public let action: Action
    public let root: String
    let git: GitService
    let login: (any GitLogin)?

    public init(_ action: Action, root: String, git: GitService, login: (any GitLogin)?) {
        self.action = action
        self.root = root
        self.git = git
        self.login = login
    }

    public var kind: OperationKind {
        switch action {
        case .pull: .gitPull
        case .push: .gitPush
        case .fetch: .gitFetch
        }
    }

    public var title: String { "\(action.verb) \((root as NSString).lastPathComponent)" }

    public func run(_ context: OperationContext) async throws {
        try await context.checkpoint()
        context.progress(nil, action == .push ? "Pushing" : action == .pull ? "Pulling" : "Fetching")
        let output = try await git.outputWithLogin(action.arguments, in: root, login: login)
        try await context.checkpoint()
        // git writes progress with carriage returns; the last state of each line is kept.
        for line in (output.stderr + output.text).split(whereSeparator: \.isNewline) {
            let last = line.split(separator: "\r").last.map(String.init) ?? ""
            if !last.trimmingCharacters(in: .whitespaces).isEmpty { context.log(last) }
        }
        guard output.succeeded else { throw GitError(output.message) }
        context.progress(1, "Done")
    }
}

extension OperationKind {
    public static let gitCheckout: OperationKind = "gitcheckout"
    public static let gitMerge: OperationKind = "gitmerge"
}

/// Checkout and merge: they change the working tree's files, so they are queue items. A
/// remote branch ("origin/feature") is checked out as the local branch tracking it.
public struct GitBranchOperation: QueueOperation {
    public enum Action: Sendable, Equatable {
        case checkout(GitBranch)
        /// Merges the branch into the current one (git's default message, never an editor).
        case merge(GitBranch, into: String)
    }

    public let action: Action
    public let root: String
    let git: GitService

    public init(_ action: Action, root: String, git: GitService) {
        self.action = action
        self.root = root
        self.git = git
    }

    public var kind: OperationKind {
        if case .merge = action { return .gitMerge }
        return .gitCheckout
    }

    public var title: String {
        switch action {
        case .checkout(let branch): "Check out \(branch.localName)"
        case .merge(let branch, let into): "Merge \(branch.name) into \(into)"
        }
    }

    public func run(_ context: OperationContext) async throws {
        try await context.checkpoint()
        let arguments: [String]
        switch action {
        case .checkout(let branch):
            context.progress(nil, "Checking out \(branch.localName)")
            if branch.isRemote {
                // An existing local branch of that name is switched to; otherwise one is made.
                let exists = (try? await git.output(["show-ref", "--verify", "--quiet", "refs/heads/" + branch.localName],
                                                    in: root))?.succeeded ?? false
                arguments = exists ? ["switch", "--", branch.localName] : ["switch", "--track", branch.name]
            } else {
                arguments = ["switch", "--", branch.name]
            }
        case .merge(let branch, _):
            context.progress(nil, "Merging \(branch.name)")
            arguments = ["merge", "--no-edit", branch.name]
        }
        let output = try await git.output(arguments, in: root)
        for line in (output.text + output.stderr).split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            context.log(String(line))
        }
        guard output.succeeded else { throw GitError(output.message) }
        context.progress(1, "Done")
    }
}
