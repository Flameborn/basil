import Foundation
import Testing
@testable import BasilUI

@Suite struct CommandLineTests {
    @Test func cdChangesThePaneFolder() {
        #expect(CommandLineAction("cd") == .changeDirectory(nil))
        #expect(CommandLineAction("cd ~") == .changeDirectory(nil))
        #expect(CommandLineAction("  cd ..  ") == .changeDirectory(".."))
        #expect(CommandLineAction("cd /Volumes/Data") == .changeDirectory("/Volumes/Data"))
        #expect(CommandLineAction("cd 'My Folder'") == .changeDirectory("My Folder"))
        #expect(CommandLineAction("cd \"My Folder\"") == .changeDirectory("My Folder"))
        #expect(CommandLineAction("cd My\\ Folder") == .changeDirectory("My Folder"))
    }

    @Test func everythingElseGoesToTheShell() {
        #expect(CommandLineAction("ls -la") == .run("ls -la"))
        #expect(CommandLineAction("cd src && make") == .run("cd src && make"))
        #expect(CommandLineAction("cd $HOME/x") == .run("cd $HOME/x"))
        #expect(CommandLineAction("cdrecord") == .run("cdrecord"))
    }

    @Test func namesAreQuotedForTheShell() {
        #expect(CommandLineBar.shellQuoted("notes.md") == "notes.md")
        #expect(CommandLineBar.shellQuoted("/a/b-c_d") == "/a/b-c_d")
        #expect(CommandLineBar.shellQuoted("My File.txt") == "'My File.txt'")
        #expect(CommandLineBar.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test func historyKeepsTheNewestFiftyWithoutRepeats() throws {
        let suite = "basil-cmdline-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = CommandHistory(defaults: defaults)
        for i in 0..<60 { history.add("echo \(i)") }
        history.add("echo 20")
        #expect(history.items.count == 50)
        #expect(history.items.last == "echo 20")
        #expect(history.items.filter { $0 == "echo 20" }.count == 1)
    }
}
