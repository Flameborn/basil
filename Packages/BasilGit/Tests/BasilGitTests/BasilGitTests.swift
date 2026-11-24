import Foundation
import Testing
@testable import BasilGit
import BasilOperations
import BasilVFS

/// A throwaway repository in the temporary folder, with its own identity and no global config.
final class TestRepository: Sendable {
    let root: URL
    let git: GitService

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("basil-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = GitService(executable: try #require(GitService.findExecutable(), "git not found"))
        try await run("init", "-q", "-b", "main")
        try await run("config", "user.name", "Basil Test")
        try await run("config", "user.email", "test@example.invalid")
        try await run("config", "commit.gpgsign", "false")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var path: String { root.path }

    @discardableResult
    func run(_ arguments: String...) async throws -> String {
        String(decoding: try await git.run(arguments, in: path), as: UTF8.self)
    }

    func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

@Suite struct GitStatusParseTests {
    @Test func parsesEveryLineKind() {
        let lines = [
            "# branch.oid 1234abcd",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaaa bbbb notes with spaces.txt",
            "1 A. N... 000000 100644 100644 0000 cccc new.txt",
            "2 R. N... 100644 100644 100644 dddd dddd R100 renamed.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 e1 e2 e3 merge.txt",
            "? untracked/",
            "? loose.txt",
            "! build/",
        ]
        let data = Data((lines.joined(separator: "\0") + "\0").utf8)
        let status = GitStatus.parse(data)
        #expect(status.branch == GitStatus.Branch(head: "main", commit: "1234abcd", upstream: "origin/main", ahead: 2, behind: 1))
        #expect(status.entries.map(\.path) == ["notes with spaces.txt", "new.txt", "renamed.txt", "merge.txt",
                                               "untracked", "loose.txt", "build"])
        #expect(status.entries[2].change == .renamed(from: "old name.txt", index: "R", worktree: "."))
        #expect(status.entries[4].isFolder && status.entries[4].change == .untracked)
        #expect(status.entries[6].isFolder && status.entries[6].change == .ignored)
    }

    @Test func initialCommitAndDetachedHead() {
        let status = GitStatus.parse(Data("# branch.oid (initial)\0# branch.head (detached)\0".utf8))
        #expect(status.branch.commit == nil && status.branch.head == nil)
    }

    @Test func columnTextPerFolder() {
        let status = GitStatus(entries: [
            .init(path: "a.txt", change: .changed(index: ".", worktree: "M"), isFolder: false),
            .init(path: "b.txt", change: .changed(index: "M", worktree: "."), isFolder: false),
            .init(path: "c.txt", change: .changed(index: "M", worktree: "M"), isFolder: false),
            .init(path: "src/deep/d.swift", change: .changed(index: ".", worktree: "M"), isFolder: false),
            .init(path: "src/e.swift", change: .untracked, isFolder: false),
            .init(path: "build", change: .ignored, isFolder: true),
            .init(path: "vendor/x", change: .ignored, isFolder: false),
            .init(path: "new", change: .untracked, isFolder: true),
        ])
        let top = status.column(forFolder: "")
        #expect(top.byName == ["a.txt": "Modified", "b.txt": "Staged", "c.txt": "Staged, modified",
                               "src": "Changes", "build": "Ignored", "new": "Untracked"])
        let src = status.column(forFolder: "src")
        #expect(src.byName == ["deep": "Changes", "e.swift": "Untracked"])
        #expect(status.column(forFolder: "build/inner").text(for: "anything") == "Ignored")
        #expect(status.column(forFolder: "new").text(for: "x") == "Untracked")
        #expect(status.column(forFolder: "elsewhere").byName.isEmpty)
    }

    @Test func relativePaths() {
        #expect(GitService.relative("/a/b/c", to: "/a/b") == "c")
        #expect(GitService.relative("/a/b", to: "/a/b/") == "")
        #expect(GitService.relative("/a/bc", to: "/a/b") == nil)
        #expect(GitService.relative("/a", to: "/") == "a")
    }
}

@Suite struct GitServiceTests {
    @Test func rootAndStatusOfARealRepository() async throws {
        let repo = try await TestRepository()
        try repo.write("tracked.txt", "one")
        try repo.write("src/code.swift", "let x = 1")
        try repo.write(".gitignore", "build/\n")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        try repo.write("tracked.txt", "two")
        try repo.write("src/code.swift", "let x = 2")
        try await repo.run("add", "src/code.swift")
        try repo.write("build/out.o", "x")
        try repo.write("fresh/a.txt", "a")
        try repo.write("ünïcode name.txt", "u")

        // The temporary folder is /var/..., git reports /private/var/...
        let root = try #require(await repo.git.repositoryRoot(of: repo.root.appendingPathComponent("src").path))
        #expect(GitService.relative(repo.path, to: root) == "")
        #expect(await repo.git.repositoryRoot(of: FileManager.default.temporaryDirectory.path) == nil)

        let status = try await repo.git.status(root: root)
        #expect(status.branch.head == "main")
        #expect(status.branch.commit != nil)
        let top = status.column(forFolder: "")
        #expect(top.byName == ["tracked.txt": "Modified", "src": "Changes", "build": "Ignored",
                               "fresh": "Untracked", "ünïcode name.txt": "Untracked"])
        #expect(status.column(forFolder: "src").byName == ["code.swift": "Staged"])

        let below = try await repo.git.status(root: root, below: repo.root.appendingPathComponent("src").path)
        #expect(below.entries.map(\.path) == ["src/code.swift"])
    }

    @Test func gitMessageOnFailure() async throws {
        let repo = try await TestRepository()
        await #expect(throws: GitError.self) { try await repo.run("checkout", "no-such-branch") }
    }
}

@Suite struct GitAnnotatorTests {
    @Test func annotatesFoldersInsideRepositoriesOnly() async throws {
        let repo = try await TestRepository()
        try repo.write("a.txt", "a")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        try repo.write("a.txt", "changed")
        try repo.write("sub/new.txt", "n")
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let annotator = GitAnnotator(git: repo.git)
        let top = try #require(await annotator.annotations(for: .local(repo.path), registry: registry))
        #expect(top.byName == ["a.txt": "Modified", "sub": "Untracked"])
        let sub = try #require(await annotator.annotations(for: .local(repo.path + "/sub"), registry: registry))
        #expect(sub.text(for: "new.txt") == "Untracked")
        #expect(await annotator.annotations(for: .local(repo.path + "/.git"), registry: registry) == nil)
        #expect(await annotator.annotations(for: .local(FileManager.default.temporaryDirectory.path), registry: registry) == nil)
    }
}

@Suite struct GitChangesTests {
    func committedRepo() async throws -> TestRepository {
        let repo = try await TestRepository()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try repo.write("gone.txt", "bye\n")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        return repo
    }

    func entry(_ status: GitStatus, _ path: String) throws -> GitStatus.Entry {
        try #require(status.entries.first { $0.path == path }, "\(status.entries)")
    }

    @Test func stageUnstageCommitAndAmend() async throws {
        let repo = try await committedRepo()
        try repo.write("a.txt", "one\n2\nthree\n")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
        try repo.write("new dir/new file.txt", "n\n")
        var status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(status.entries.map(\.path).sorted() == ["a.txt", "gone.txt", "new dir/new file.txt"])
        #expect(try entry(status, "a.txt").staging == .notStaged)

        try await repo.git.stage(["a.txt", "gone.txt", "new dir/new file.txt"], root: repo.path)
        status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(status.entries.allSatisfy { $0.staging == .staged })
        #expect(GitStatus.text(for: try entry(status, "gone.txt").change) == "Deleted")

        try await repo.git.unstage(["new dir/new file.txt"], root: repo.path, hasCommit: true)
        status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(try entry(status, "new dir/new file.txt").change == .untracked)

        try await repo.git.commit(message: "second\n\nbody line", amend: false, root: repo.path)
        #expect(await repo.git.lastCommitMessage(root: repo.path) == "second\n\nbody line")
        try await repo.git.commit(message: "second, better", amend: true, root: repo.path)
        #expect(await repo.git.lastCommitMessage(root: repo.path) == "second, better")
        #expect(try await repo.run("rev-list", "--count", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "2")

        await #expect(throws: GitError.self) { try await repo.git.commit(message: "empty", amend: false, root: repo.path) }
    }

    @Test func unstageBeforeTheFirstCommit() async throws {
        let repo = try await TestRepository()
        try repo.write("x.txt", "x")
        try await repo.git.stage(["x.txt"], root: repo.path)
        try await repo.git.unstage(["x.txt"], root: repo.path, hasCommit: false)
        let status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(status.entries.map(\.change) == [.untracked])
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("x.txt").path))
    }

    @Test func diffAgainstTheLastCommit() async throws {
        let repo = try await committedRepo()
        try repo.write("a.txt", "one\n2\nthree\nfour")
        try repo.write("fresh.txt", "hello\n")
        let status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        let diff = try await repo.git.diff(of: try entry(status, "a.txt"), root: repo.path, hasCommit: true)
        #expect(diff.lines.map(\.kind) == [.hunk, .same, .removed, .added, .same, .added, .note])
        #expect(GitDiff.spoken(diff.lines[2]) == "Removed, line 2: two")
        #expect(GitDiff.spoken(diff.lines[3]) == "Added, line 2: 2")
        #expect(GitDiff.spoken(diff.lines[5]) == "Added, line 4: four")
        #expect(diff.lines[6].text == "No newline at end of file")

        let fresh = try await repo.git.diff(of: try entry(status, "fresh.txt"), root: repo.path, hasCommit: true)
        #expect(fresh.lines.map(\.kind) == [.hunk, .added])
        #expect(fresh.lines[1].text == "hello")
    }

    @Test func binaryDiffHasANote() {
        let diff = GitDiff.parse("diff --git a/x.bin b/x.bin\nindex 1..2 100644\nBinary files a/x.bin and b/x.bin differ\n")
        #expect(diff.isBinary && diff.lines.isEmpty && diff.note == "Binary file, no line differences")
    }
}

@MainActor
@Suite struct DiscardChangesTests {
    @Test func restoresTrackedFilesAndTrashesNewOnes() async throws {
        let repo = try await TestRepository()
        try repo.write("a.txt", "committed\n")
        try repo.write("old name.txt", "o\n")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        try repo.write("a.txt", "changed\n")
        try await repo.run("mv", "old name.txt", "new name.txt")
        try repo.write("added.txt", "staged new\n")
        try await repo.run("add", "added.txt")
        try repo.write("loose.txt", "untracked\n")
        let status = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(status.entries.count == 4)

        let trashed = Recorded()
        let op = DiscardChangesOperation(entries: status.entries, root: repo.path, hasCommit: true, git: repo.git) { path in
            trashed.add(path.path)
            try FileManager.default.removeItem(atPath: path.path)
        }
        let queue = FileOperationQueue()
        let item = queue.add(op)
        while !item.state.isDone { try await Task.sleep(for: .milliseconds(20)) }
        #expect(item.state == .finished, "\(item.log)")
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a.txt"), encoding: .utf8) == "committed\n")
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("old name.txt").path))
        #expect(trashed.all.map { ($0 as NSString).lastPathComponent }.sorted() == ["added.txt", "loose.txt", "new name.txt"])
        let after = try await repo.git.status(root: repo.path, ignored: false, untrackedFiles: true)
        #expect(after.entries.isEmpty, "\(after.entries)")
    }
}

final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// Plays the user at the login sheet.
final class ScriptedLogin: GitLogin, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(GitPrompt, Int)] = []
    private var results: [Bool] = []
    let answers: (GitPrompt, Int) -> String?
    init(_ answers: @escaping (GitPrompt, Int) -> String?) { self.answers = answers }
    func answer(_ prompt: GitPrompt, attempt: Int) async -> String? {
        lock.withLock { asked.append((prompt, attempt)) }
        return answers(prompt, attempt)
    }
    func finished(succeeded: Bool) async { lock.withLock { results.append(succeeded) } }
    var prompts: [GitPrompt] { lock.withLock { asked.map(\.0) } }
    var outcomes: [Bool] { lock.withLock { results } }
}

@Suite struct GitAskPassTests {
    /// A stand-in for Basil's own executable in askpass mode: the same protocol, in sh.
    func askPassScript() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-askpass-test-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        reply=$( { printf '%s\\n' "$BASIL_GIT_ASKPASS_TOKEN"; printf '%s' "$1" | base64; } | nc -U "$BASIL_GIT_ASKPASS_SOCKET" )
        case "$reply" in OK\\ *) printf '%s\\n' "${reply#OK }" | base64 -D; echo ;; *) exit 1 ;; esac
        """
        try Data(script.utf8).write(to: url)
        chmod(url.path, 0o755)
        return url.path
    }

    @Test func credentialPromptsGoThroughTheLogin() async throws {
        let repo = try await TestRepository()
        let script = try askPassScript()
        defer { try? FileManager.default.removeItem(atPath: script) }
        let git = GitService(executable: try #require(GitService.findExecutable()), askPassExecutable: script)
        let login = ScriptedLogin { prompt, _ in prompt.kind == .text ? "alice" : "s3cret pw" }
        // No credential helper: git asks for both through GIT_ASKPASS.
        let output = try await git.outputWithLogin(["-c", "credential.helper=", "credential", "fill"], in: repo.path,
                                                   login: login, input: Data("protocol=https\nhost=example.invalid\n\n".utf8))
        #expect(output.succeeded, "\(output.stderr)")
        #expect(output.text.contains("username=alice"))
        #expect(output.text.contains("password=s3cret pw"))
        #expect(login.prompts.map(\.kind) == [.text, .secret])
        #expect(login.prompts.first?.text.contains("example.invalid") == true)
        #expect(login.outcomes == [true])
    }

    @Test func cancelledLoginFails() async throws {
        let repo = try await TestRepository()
        let script = try askPassScript()
        defer { try? FileManager.default.removeItem(atPath: script) }
        let git = GitService(executable: try #require(GitService.findExecutable()), askPassExecutable: script)
        let login = ScriptedLogin { _, _ in nil }
        let output = try await git.outputWithLogin(["-c", "credential.helper=", "credential", "fill"], in: repo.path,
                                                   login: login, input: Data("protocol=https\nhost=example.invalid\n\n".utf8))
        #expect(!output.succeeded)
        #expect(login.outcomes == [false])
    }

    @Test func promptKinds() {
        #expect(GitPrompt(text: "Username for 'https://github.com': ").kind == .text)
        #expect(GitPrompt(text: "Password for 'https://a@github.com': ").kind == .secret)
        #expect(GitPrompt(text: "Enter passphrase for key '/Users/a/.ssh/id_ed25519': ").kind == .secret)
        #expect(GitPrompt(text: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ").kind == .yesNo)
    }
}

@MainActor
@Suite struct GitRemoteOperationTests {
    @Test func pushAndPullThroughALocalRemote() async throws {
        let origin = FileManager.default.temporaryDirectory.appendingPathComponent("basil-git-origin-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: origin) }
        let repo = try await TestRepository()
        try await repo.run("init", "-q", "--bare", "-b", "main", origin.path)
        try repo.write("a.txt", "a")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        try await repo.run("remote", "add", "origin", origin.path)
        try await repo.run("push", "-q", "-u", "origin", "main")
        try repo.write("a.txt", "b")
        try await repo.git.stage(["a.txt"], root: repo.path)
        try await repo.git.commit(message: "second", amend: false, root: repo.path)

        let queue = FileOperationQueue()
        func run(_ action: GitRemoteOperation.Action) async throws -> QueueItem {
            let item = queue.add(GitRemoteOperation(action, root: repo.path, git: repo.git, login: nil))
            while !item.state.isDone { try await Task.sleep(for: .milliseconds(20)) }
            return item
        }
        let push = try await run(.push)
        #expect(push.state == .finished, "\(push.log)")
        #expect(push.kind == .gitPush)
        let remoteLog = String(decoding: try await repo.git.run(["--git-dir", origin.path, "log", "--format=%s"], in: repo.path),
                               as: UTF8.self)
        #expect(remoteLog.hasPrefix("second"))
        let fetch = try await run(.fetch)
        #expect(fetch.state == .finished, "\(fetch.log)")
        let pull = try await run(.pull)
        #expect(pull.state == .finished, "\(pull.log)")

        try await repo.run("remote", "set-url", "origin", origin.path + "-missing")
        let failed = try await run(.push)
        if case .failed = failed.state {} else { Issue.record("not failed: \(failed.state)") }
    }
}

@MainActor
@Suite struct GitBranchTests {
    func run(_ queue: FileOperationQueue, _ op: GitBranchOperation) async throws -> QueueItem {
        let item = queue.add(op)
        while !item.state.isDone { try await Task.sleep(for: .milliseconds(20)) }
        return item
    }

    @Test func listCreateRenameDeleteCheckoutMerge() async throws {
        let origin = FileManager.default.temporaryDirectory.appendingPathComponent("basil-git-origin-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: origin) }
        let repo = try await TestRepository()
        try repo.write("a.txt", "a\n")
        try await repo.run("add", ".")
        try await repo.run("commit", "-q", "-m", "first")
        try await repo.run("init", "-q", "--bare", "-b", "main", origin.path)
        try await repo.run("remote", "add", "origin", origin.path)
        try await repo.run("push", "-q", "-u", "origin", "main")
        try await repo.run("push", "-q", "origin", "main:remote-only")
        try await repo.run("fetch", "-q", "origin")

        try await repo.git.createBranch("feature", switchTo: true, root: repo.path)
        try repo.write("f.txt", "f\n")
        try await repo.git.stage(["f.txt"], root: repo.path)
        try await repo.git.commit(message: "feature work", amend: false, root: repo.path)

        var branches = try await repo.git.branches(root: repo.path)
        #expect(branches.map(\.name) == ["feature", "main", "origin/main", "origin/remote-only"])
        #expect(branches.first { $0.isCurrent }?.name == "feature")
        #expect(branches[0].subject == "feature work")
        #expect(branches[1].upstream == "origin/main")
        #expect(branches[3].isRemote && branches[3].localName == "remote-only")

        #expect(await repo.git.isValidBranchName("ok-name", root: repo.path))
        #expect(!(await repo.git.isValidBranchName("bad..name", root: repo.path)))

        let queue = FileOperationQueue()
        let main = try #require(branches.first { $0.name == "main" })
        #expect(try await run(queue, GitBranchOperation(.checkout(main), root: repo.path, git: repo.git)).state == .finished)
        // feature is not merged into main: a plain delete refuses.
        do {
            try await repo.git.deleteBranch("feature", force: false, root: repo.path)
            Issue.record("deleted an unmerged branch")
        } catch let error as GitError {
            #expect(error.isNotMerged, "\(error.message)")
        }
        let feature = try #require(branches.first { $0.name == "feature" })
        let merge = try await run(queue, GitBranchOperation(.merge(feature, into: "main"), root: repo.path, git: repo.git))
        #expect(merge.state == .finished, "\(merge.log)")
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("f.txt").path))
        try await repo.git.deleteBranch("feature", force: false, root: repo.path)

        let remoteOnly = try #require(branches.first { $0.name == "origin/remote-only" })
        #expect(try await run(queue, GitBranchOperation(.checkout(remoteOnly), root: repo.path, git: repo.git)).state == .finished)
        try await repo.git.renameBranch("remote-only", to: "renamed", root: repo.path)
        branches = try await repo.git.branches(root: repo.path)
        let current = try #require(branches.first { $0.isCurrent })
        #expect(current.name == "renamed" && current.upstream == "origin/remote-only")
    }

    @Test func parsesTrackingState() {
        let line = ["refs/heads/x", "x", "abc1234", "origin/x", "[ahead 2, behind 1]", " ", "1700000000", "Subject with spaces"]
            .joined(separator: "\0")
        let gone = ["refs/heads/y", "y", "abc1235", "origin/y", "[gone]", "*", "1700000000", "S"].joined(separator: "\0")
        let head = ["refs/remotes/origin/HEAD", "origin", "abc", "", "", " ", "1", "s"].joined(separator: "\0")
        let branches = GitService.parseBranches([line, gone, head].joined(separator: "\n"))
        #expect(branches.count == 2)
        #expect(branches[0].ahead == 2 && branches[0].behind == 1 && !branches[0].upstreamGone)
        #expect(branches[1].upstreamGone && branches[1].isCurrent)
    }
}
