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

    /// With BASIL_UITEST_LEFTOVERS=1: where the fake app's leftovers are (home, /Library, /var/folders, receipts).
    nonisolated(unsafe) static var leftoverPlaces: URL?

    /// Beta/Leftie.app (bundle ID com.example.BasilLeftie) and three leftovers of it in a fake home.
    private static func makeLeftovers(app: URL, places: URL) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.BasilLeftie", "CFBundleName": "Leftie",
                                   "CFBundleExecutable": "Leftie", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/Leftie"))
        for path in ["home/Library/Preferences/com.example.BasilLeftie.plist",
                     "home/Library/Caches/com.example.BasilLeftie/cache.db",
                     "var/T/com.example.BasilLeftie/scratch"] {
            let url = places.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createDirectory(at: places.appendingPathComponent("var/C"), withIntermediateDirectories: true)
        leftoverPlaces = places
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
            if ProcessInfo.processInfo.environment["BASIL_UITEST_ENCRYPTED_7Z"] == "1" {
                try makeEncrypted7z(at: root.appendingPathComponent("Alpha/Inner/secret.7z"))
            }
            if ProcessInfo.processInfo.environment["BASIL_UITEST_LEFTOVERS"] == "1" {
                try makeLeftovers(app: root.appendingPathComponent("Beta/Leftie.app"),
                                  places: temp.appendingPathComponent("basil-uitest-leftovers-\(ProcessInfo.processInfo.processIdentifier)"))
            }
            if ProcessInfo.processInfo.environment["BASIL_UITEST_RAR"] == "1" {
                try Data(base64Encoded: rar4Archive.joined())!.write(to: root.appendingPathComponent("Alpha/Inner/old.rar"))
            }
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

    /// Alpha/Inner/secret.7z with note.txt, names and data encrypted with the password "basil",
    /// made with the bundled 7zz (the password goes in through stdin).
    private static func makeEncrypted7z(at url: URL) throws {
        let fm = FileManager.default
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "7zz") else { throw CocoaError(.fileNoSuchFile) }
        let staging = fm.temporaryDirectory.appendingPathComponent("basil-uitest-7z-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: staging.appendingPathComponent("note.txt"))
        let sevenZip = Process()
        sevenZip.executableURL = tool
        sevenZip.arguments = ["a", "-p", "-mhe=on", url.path, "note.txt"]
        sevenZip.currentDirectoryURL = staging
        let input = Pipe()
        sevenZip.standardInput = input
        sevenZip.standardOutput = FileHandle.nullDevice
        try sevenZip.run()
        try input.fileHandleForWriting.write(contentsOf: Data("basil\n".utf8))
        try input.fileHandleForWriting.close()
        sevenZip.waitUntilExit()
    }

    /// Alpha/Inner/old.rar: libarchive's test_read_format_rar.rar (RAR 4; test.txt, testdir with
    /// test.txt, testemptydir, and testlink pointing to test.txt). Nothing on macOS makes RAR archives.
    private static let rar4Archive = [
        "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRl",
        "c3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0",
        "LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQg",
        "ZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAA",
        "AAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA",
    ]

    nonisolated(unsafe) private static var createdRoot: URL?

    static func cleanup() {
        if let root = createdRoot { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
