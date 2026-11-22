#if DEBUG
import BasilCore
import Foundation

/// Debug-only: when launched with BASIL_UITEST_FIXTURE=1, builds a known directory tree and
/// starts both panes in it. Needed because Xcode sandboxes the UI-test runner, so files it
/// creates live in its container, which other apps (Basil) are not allowed to read.
enum UITestFixture {
    static var isActive: Bool { ProcessInfo.processInfo.environment["BASIL_UITEST_FIXTURE"] == "1" }

    /// A separate preferences domain, wiped at each launch, so tests never touch the user's settings.
    static func isolatedDefaults() -> UserDefaults? {
        guard isActive else { return nil }
        let suite = "com.erion.basil.uitests"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)
    }

    static func makeIfRequested() -> (left: VFSPath, right: VFSPath)? {
        guard ProcessInfo.processInfo.environment["BASIL_UITEST_FIXTURE"] == "1" else { return nil }
        let fm = FileManager.default
        // XCUIApplication.terminate() kills the app without applicationWillTerminate,
        // so remove fixtures left by earlier runs first.
        let temp = fm.temporaryDirectory
        for old in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where old.hasPrefix("basil-uitest-") {
            try? fm.removeItem(at: temp.appendingPathComponent(old))
        }
        let root = temp.appendingPathComponent("basil-uitest-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try fm.createDirectory(at: root.appendingPathComponent("Alpha/Inner"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("Beta"), withIntermediateDirectories: true)
            for name in ["apple pie.txt", "song.mp3", "track.flac", "notes.md", ".secret"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
            try makeZip(at: root.appendingPathComponent("Alpha/Inner/pack.zip"))
        } catch {
            return nil
        }
        createdRoot = root
        return (.local(root.path), .local(root.appendingPathComponent("Beta").path))
    }

    /// Alpha/Inner/pack.zip with docs/readme.txt and top.txt, made with the system zip tool.
    private static func makeZip(at url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("basil-uitest-zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: staging.appendingPathComponent("docs/readme.txt"))
        try Data("top".utf8).write(to: staging.appendingPathComponent("top.txt"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.path, "docs", "top.txt"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
    }

    nonisolated(unsafe) private static var createdRoot: URL?

    static func cleanup() {
        if let root = createdRoot { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
