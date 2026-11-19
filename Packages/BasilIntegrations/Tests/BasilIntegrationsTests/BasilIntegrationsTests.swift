import Foundation
import Testing
@testable import BasilIntegrations

@Suite struct TerminalLauncherTests {
    @Test func quotesFolderForTheShell() {
        #expect(TerminalLauncher.expand("open -a Foo {dir}", folder: "/tmp/it's here") == #"open -a Foo '/tmp/it'\''s here'"#)
    }

    @Test @MainActor func customCommandRunsInFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("basil-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await TerminalLauncher.open(dir, terminalID: "custom", command: "pwd -P > {dir}/out.txt")
        let out = dir.appendingPathComponent("out.txt")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(50))
        let text = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.hasSuffix(dir.path))
    }

    @Test @MainActor func emptyCustomCommandFails() async {
        await #expect(throws: TerminalLaunchError.self) {
            try await TerminalLauncher.open(URL(fileURLWithPath: "/tmp"), terminalID: "custom", command: " ")
        }
    }
}
