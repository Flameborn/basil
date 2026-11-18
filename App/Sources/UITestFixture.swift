#if DEBUG
import BasilCore
import Foundation

/// Debug-only: when launched with BASIL_UITEST_FIXTURE=1, builds a known directory tree and
/// starts both panes in it. Needed because Xcode sandboxes the UI-test runner, so files it
/// creates live in its container, which other apps (Basil) are not allowed to read.
enum UITestFixture {
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
        } catch {
            return nil
        }
        createdRoot = root
        return (.local(root.path), .local(root.appendingPathComponent("Beta").path))
    }

    nonisolated(unsafe) private static var createdRoot: URL?

    static func cleanup() {
        if let root = createdRoot { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
