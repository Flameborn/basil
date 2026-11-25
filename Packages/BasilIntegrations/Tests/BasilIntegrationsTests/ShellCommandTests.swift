import Foundation
import Testing
@testable import BasilIntegrations

@Suite struct TerminalTextTests {
    @Test func removesColoursAndTitles() {
        #expect(TerminalText.clean("\u{1B}[1;31mred\u{1B}[0m plain\n") == "red plain\n")
        #expect(TerminalText.clean("\u{1B}]0;title\u{07}text") == "text")
        #expect(TerminalText.clean("\u{1B}]2;title\u{1B}\\text") == "text")
        #expect(TerminalText.clean("a\u{1B}[?25lb") == "ab")
    }

    @Test func carriageReturnKeepsTheLastStateOfALine() {
        #expect(TerminalText.clean("10%\r50%\r100%\ndone\n") == "100%\ndone\n")
        #expect(TerminalText.clean("windows\r\nline\r\n") == "windows\nline\n")
    }

    @Test func backspaceAndControlCharacters() {
        #expect(TerminalText.clean("abc\u{08}d\u{07}\tx") == "abd\tx")
    }
}

@Suite struct ShellCommandTests {
    @MainActor final class Collector {
        var text = ""
        var outcome: ShellCommand.Outcome?
    }

    @MainActor
    private func run(_ command: String, in folder: URL, shell path: String? = nil,
                     stopAfter: Duration? = nil) async throws -> (String, ShellCommand.Outcome) {
        let collector = Collector()
        let shell = ShellCommand(command, in: folder, shell: path)
        try shell.start(output: { collector.text += $0 }, finished: { collector.outcome = $0 })
        if let stopAfter {
            try await Task.sleep(for: stopAfter)
            shell.stop()
        }
        for _ in 0..<200 where collector.outcome == nil { try await Task.sleep(for: .milliseconds(50)) }
        // Output tasks queued before the outcome have run by now; one more turn to be sure.
        try await Task.sleep(for: .milliseconds(20))
        return (collector.text, try #require(collector.outcome))
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("basil-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    @Test @MainActor func runsInTheFolderWithMergedOutput() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (text, outcome) = try await run("/bin/pwd -P; echo oops 1>&2", in: dir)
        #expect(outcome == .exited(0))
        #expect(text.contains(dir.path))
        #expect(text.contains("oops"))
    }

    @Test @MainActor func runsInTheChosenShell() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (text, outcome) = try await run("echo \"bash $BASH_VERSION\"", in: dir, shell: "/bin/bash")
        #expect(outcome == .exited(0))
        #expect(text.hasPrefix("bash ") && text.count > "bash \n".count)
        #expect(ShellCommand("true", in: dir, shell: "").shell == ShellCommand.loginShell)
    }

    static let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: fish != nil, "fish is not installed")) @MainActor
    func runsInFish() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (text, outcome) = try await run("echo fish $FISH_VERSION; status is-login; and echo login", in: dir, shell: Self.fish)
        #expect(outcome == .exited(0))
        #expect(text.contains("fish "))
        #expect(text.contains("login\n"))
    }

    @Test @MainActor func aMissingShellFailsToStart() throws {
        let shell = ShellCommand("true", in: FileManager.default.temporaryDirectory, shell: "/no/such/shell")
        #expect(throws: (any Error).self) { try shell.start(output: { _ in }, finished: { _ in }) }
    }

    @Test func installedShellsListEachExistingShellOnce() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shells")
        try "# comment\n/bin/zsh\n/bin/zsh\n/no/such/shell\n\n/bin/bash\n".write(to: file, atomically: true, encoding: .utf8)
        let shells = ShellCommand.installedShells(shellsFile: file.path)
        #expect(Array(shells.prefix(2)) == ["/bin/zsh", "/bin/bash"])
        #expect(!shells.contains("/no/such/shell"))
        if let fish = Self.fish { #expect(shells.contains(fish)) }
    }

    @Test @MainActor func reportsTheExitStatus() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, outcome) = try await run("exit 3", in: dir)
        #expect(outcome == .exited(3))
    }

    @Test @MainActor func inputIsEmpty() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (text, outcome) = try await run("/bin/cat; echo end", in: dir)
        #expect(outcome == .exited(0))
        #expect(text == "end\n")
    }

    @Test @MainActor func stopEndsTheCommandAndItsChildren() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let (_, outcome) = try await run("/bin/sleep 30; echo late", in: dir, stopAfter: .milliseconds(500))
        #expect(outcome == .stopped)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct FullDiskAccessTests {
    @Test func readableFileMeansGranted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("basil-fda-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("closed").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let open = dir.appendingPathComponent("open").path
        let closed = dir.appendingPathComponent("closed").path
        let missing = dir.appendingPathComponent("missing").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: open))
        try Data("x".utf8).write(to: URL(fileURLWithPath: closed))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed)

        #expect(FullDiskAccess.status(files: [missing, open]) == .granted)
        #expect(FullDiskAccess.status(files: [missing, closed]) == .notGranted)
        #expect(FullDiskAccess.status(files: [closed, open]) == .granted)
        #expect(FullDiskAccess.status(files: [missing]) == .unknown)
        #expect(FullDiskAccess.Status.unknown.allowsContinuing)
        #expect(!FullDiskAccess.Status.notGranted.allowsContinuing)
    }
}
