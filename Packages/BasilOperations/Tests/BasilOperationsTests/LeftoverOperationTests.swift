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
}
