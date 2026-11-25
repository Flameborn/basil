import Foundation
import Testing
@testable import BasilOperations

@Suite struct LeftoverOperationTests {
    @Test func adminScriptQuotesEveryPath() {
        let script = RemoveLeftoversOperation.adminScript(for: [#"/Library/It's "odd"\x"#, "/Library/b"], toTrash: false, trash: "/Users/u/.Trash")
        #expect(script.contains(#"quoted form of "/Library/It's \"odd\"\\x""#))
        #expect(script.contains(#"& " && ""#))
        #expect(script.hasSuffix("do shell script cmd with administrator privileges"))
        let trash = RemoveLeftoversOperation.adminScript(for: ["/Library/a"], toTrash: true, trash: "/Users/u/.Trash")
        #expect(trash.contains("/bin/mv -n -- ") && trash.contains(#"quoted form of "/Users/u/.Trash/a "#))
        #expect(!trash.contains(#"& " && ""#))
    }

    /// The script itself is valid AppleScript (compiled, not run).
    @Test func adminScriptCompiles() throws {
        let script = RemoveLeftoversOperation.adminScript(for: ["/Library/a b", "/Library/c"], toTrash: true, trash: "/Users/u/.Trash")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("basil-\(UUID().uuidString).applescript")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", file.path + ".scpt", file.path]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: file.path + ".scpt")
        #expect(process.terminationStatus == 0)
    }

    /// A failing script with a lot of error output (one line per file of a big app) ends with
    /// the error instead of blocking on a full pipe.
    @Test(.timeLimit(.minutes(1))) func longErrorOutputDoesNotBlock() async throws {
        let script = #"do shell script "for i in $(seq 1 6000); do echo \"chown: /x/$i: Operation not permitted\" >&2; done; exit 1""#
        do {
            try await AdministratorRemoval.runAppleScript(script)
            Issue.record("the script should fail")
        } catch let failed as AdministratorRemoval.Failed {
            let described = AdministratorRemoval.Failed(message: failed.message, paths: ["/Applications/Big.app"]).errorDescription ?? ""
            #expect(described.contains("Operation not permitted"))
            #expect(described.contains("App Management"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingStopsTheScript() async throws {
        let started = ContinuousClock.now
        let flag = CancelFlag()
        Task { try await Task.sleep(for: .milliseconds(500)); flag.set() }
        await #expect(throws: CancellationError.self) {
            try await AdministratorRemoval.runAppleScript(#"do shell script "sleep 20""#, isCancelled: { flag.isSet })
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
