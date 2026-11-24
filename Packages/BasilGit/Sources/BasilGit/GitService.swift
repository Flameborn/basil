import Foundation
import Synchronization

/// Errors from git, already in words.
public struct GitError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Wraps the system git command-line tool (never libgit2). Every call runs git on this
/// service's own dispatch queue, never on the cooperative pool, and parses porcelain or -z
/// output. Paths are plain file-system paths: git only works on local folders (also on a
/// mounted share).
public final class GitService: Sendable {
    let tool: GitProcess
    /// The program git and ssh run to ask for a login (GIT_ASKPASS, SSH_ASKPASS): Basil's own
    /// executable, which hands the question to the running app (`GitAskPass`). nil: no login
    /// can be asked for.
    public let askPassExecutable: String?
    private let queue = DispatchQueue(label: "basil.git", qos: .userInitiated, attributes: .concurrent)

    public init(executable: URL, askPassExecutable: String? = nil) {
        tool = GitProcess(executable: executable)
        self.askPassExecutable = askPassExecutable
    }

    /// The git to use: Homebrew's, then /usr/local, then Apple's (/usr/bin/git, which needs the
    /// Command Line Tools). nil when none is there.
    public static func findExecutable(candidates: [String] = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs git in `directory` and throws git's message when it fails.
    @discardableResult
    public func run(_ arguments: [String], in directory: String, input: Data? = nil,
                    environment: [String: String] = [:]) async throws -> Data {
        let output = try await output(arguments, in: directory, input: input, environment: environment)
        guard output.succeeded else { throw GitError(output.message) }
        return output.stdout
    }

    func output(_ arguments: [String], in directory: String, input: Data? = nil,
                environment: [String: String] = [:]) async throws -> GitProcess.Output {
        let tool = tool
        // A cancelled caller (a queue item) stops git: SIGTERM to the process it started.
        let process = Mutex<(pid: pid_t?, cancelled: Bool)>((nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try tool.run(arguments, in: URL(fileURLWithPath: directory, isDirectory: true), input: input,
                                     environment: environment) { pid in
                            let cancelled = process.withLock { state in
                                state.pid = pid
                                return state.cancelled
                            }
                            if cancelled { kill(pid, SIGTERM) }
                        }
                    })
                }
            }
        } onCancel: {
            if let pid = process.withLock({ state -> pid_t? in
                state.cancelled = true
                return state.pid
            }) { kill(pid, SIGTERM) }
        }
    }

    /// The working tree holding `directory` and its git folders (the worktree's own and the
    /// shared one, which differ for linked worktrees), or nil outside any working tree.
    public func repository(of directory: String) async -> (root: String, gitDirectories: [String])? {
        guard let output = try? await output(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
                                             in: directory), output.succeeded else { return nil }
        let lines = output.text.split(separator: "\n").map(String.init)
        guard lines.count == 3, !lines[0].isEmpty else { return nil }
        // --git-common-dir may be relative to the folder git ran in.
        let common = lines[2].hasPrefix("/") ? lines[2]
            : URL(fileURLWithPath: lines[2], relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
        return (lines[0], Array(Set([lines[1], Self.realPath(common) ?? common])).sorted())
    }

    /// The top folder of the working tree that holds `directory`, or nil when it is in none
    /// (also inside a .git folder).
    public func repositoryRoot(of directory: String) async -> String? {
        guard let output = try? await output(["rev-parse", "--show-toplevel"], in: directory), output.succeeded else { return nil }
        let root = output.text.trimmingCharacters(in: .newlines)
        return root.isEmpty ? nil : root
    }

    /// The status of the working tree below `folder` (a path inside `root`; the whole tree
    /// when nil). Untracked and ignored folders come as one entry each, unless `untrackedFiles`
    /// lists every untracked file (the Commit window).
    public func status(root: String, below folder: String? = nil, ignored: Bool = true,
                       untrackedFiles: Bool = false) async throws -> GitStatus {
        var arguments = ["status", "--porcelain=v2", "-z", "--branch",
                         untrackedFiles ? "--untracked-files=all" : "--untracked-files=normal"]
        if ignored { arguments.append("--ignored=matching") }
        if let folder, let relative = Self.relative(folder, to: root), !relative.isEmpty {
            arguments += ["--", ":(literal)" + relative]
        }
        return GitStatus.parse(try await run(arguments, in: root))
    }

    /// `path` relative to `root` ("" for the root itself), or nil when it is not inside it.
    /// git names the root by its real path (/private/var/... for /var/...), so a path that
    /// does not match as given is compared through realpath.
    public static func relative(_ path: String, to root: String) -> String? {
        if let direct = plainRelative(path, to: root) { return direct }
        guard let real = realPath(path) else { return nil }
        return plainRelative(real, to: realPath(root) ?? root)
    }

    private static func plainRelative(_ path: String, to root: String) -> String? {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == root { return "" }
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
