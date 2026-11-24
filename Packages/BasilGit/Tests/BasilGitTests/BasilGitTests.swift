import Foundation
import Testing
@testable import BasilGit
import BasilVFS

/// A throwaway repository in the temporary folder, with its own identity and no global config.
final class TestRepository {
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
