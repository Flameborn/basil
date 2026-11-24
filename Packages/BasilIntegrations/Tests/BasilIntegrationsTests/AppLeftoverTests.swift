import Foundation
import Testing
@testable import BasilIntegrations

@Suite struct AppLeftoverTests {
    /// A fake app with a helper, and a fake home, /Library, /var/folders and receipts folder.
    struct Box {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var system: URL { root.appendingPathComponent("Library") }
        var cache: URL { root.appendingPathComponent("var/C") }
        var temp: URL { root.appendingPathComponent("var/T") }
        var receipts: URL { root.appendingPathComponent("receipts") }
        var app: URL { root.appendingPathComponent("Apps/Leftie.app") }
        var roots: AppLeftoverFinder.Roots {
            .init(home: home, systemLibrary: system, userCache: cache, userTemp: temp, receipts: receipts)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("basil-leftovers-\(UUID().uuidString)")
            try Self.bundle(at: app, id: "com.example.Leftie", name: "Leftie", executable: "Leftie")
            try Self.bundle(at: app.appendingPathComponent("Contents/Library/LoginItems/LeftieHelper.app"),
                            id: "com.example.Leftie.Helper", name: "LeftieHelper", executable: "LeftieHelper")
            // An extension whose executable is not named after the app (its crash reports are not the app's).
            try Self.bundle(at: app.appendingPathComponent("Contents/PlugIns/Ext.appex"),
                            id: "com.example.Leftie.ext", name: "Ext", executable: "Safari")
            // A bundled updater with a shared ID: its files are not the app's.
            try Self.bundle(at: app.appendingPathComponent("Contents/XPCServices/Updater.xpc"),
                            id: "org.updater.Installer", name: "Updater", executable: "Updater")
        }

        static func bundle(at url: URL, id: String, name: String, executable: String) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": executable,
                                       "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data().write(to: contents.appendingPathComponent("MacOS/\(executable)"))
        }

        @discardableResult
        func file(_ base: URL, _ path: String, _ data: Data = Data("x".utf8)) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func plist(_ base: URL, _ path: String, _ value: [String: Any]) throws {
            try file(base, path, try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
        }
    }

    @Test func identityReadsIDsNamesAndOwnHelpersOnly() throws {
        let box = try Box()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let identity = try #require(AppIdentity.read(appAt: box.app))
        #expect(identity.bundleID == "com.example.Leftie")
        #expect(Set(identity.helperIDs) == ["com.example.Leftie.Helper", "com.example.Leftie.ext"])
        #expect(identity.names == ["Leftie"])
        #expect(identity.executables == ["Leftie", "LeftieHelper"])
    }

    @Test func findsLeftoversEverywhereAndNothingElse() throws {
        let box = try Box()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let lib = box.home.appendingPathComponent("Library")
        let expected = [
            "home/Library/Application Support/com.example.Leftie/data.db",
            "home/Library/Caches/Leftie/cache.bin",                       // by name
            "home/Library/Caches/com.example.Leftie/a",
            "home/Library/Containers/com.example.Leftie.Helper/c",        // the helper's container
            "home/Library/Preferences/com.example.Leftie.plist",
            "home/Library/Preferences/ByHost/com.example.Leftie.0000-1111.plist",
            "home/Library/Saved Application State/com.example.Leftie.savedState/w",
            "home/Library/Logs/DiagnosticReports/Leftie-2026-11-22-101010.ips",
            "home/Library/HTTPStorages/com.example.Leftie.binarycookies",
            "home/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.leftie.sfl3",
            "var/C/com.example.Leftie/x",
            "var/T/com.example.Leftie/y",
            "Library/Application Support/Leftie/z",
            "Library/PrivilegedHelperTools/com.example.Leftie.Helper",
            "receipts/com.example.Leftie.pkg.bom",
        ]
        for path in expected { try box.file(box.root, path) }
        // launchd: one by label, one by its program inside the app.
        try box.plist(lib, "LaunchAgents/com.example.Leftie.agent.plist", ["Label": "com.example.Leftie.agent"])
        try box.plist(box.system, "LaunchDaemons/updater.plist",
                      ["Label": "net.other.updater", "ProgramArguments": [box.app.path + "/Contents/MacOS/Leftie", "--daemon"]])
        // Not the app's.
        let unrelated = [
            "home/Library/Preferences/com.example.LeftieOther.plist",
            "home/Library/Preferences/com.example.plist",
            "home/Library/Caches/Leftie Pro/x",
            "home/Library/Caches/org.updater.Installer/x",
            "home/Library/Containers/com.example.Other/x",
            "home/Library/Logs/DiagnosticReports/LeftieOther-2026-11-22.ips",
            "home/Library/Application Support/CrashReporter/Safari_6F1F43F4.plist",
            "Library/Preferences/Leftie.plist",                             // names only count in support, cache and log folders
        ]
        for path in unrelated { try box.file(box.root, path) }
        try box.plist(lib, "LaunchAgents/net.other.plist", ["Label": "net.other", "Program": "/usr/bin/true"])

        let identity = try #require(AppIdentity.read(appAt: box.app))
        let found = AppLeftoverFinder(roots: box.roots).find(for: identity)
        let rel = Set(found.map { String($0.url.standardizedFileURL.path.dropFirst(box.root.standardizedFileURL.path.count + 1)) })
        let tops = Set(expected.map { path in
            // The leftover is the entry directly in the searched folder.
            let parts = path.split(separator: "/").map(String.init)
            let depth = [
                "home/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/": 7,
                "home/Library/Preferences/ByHost/": 5, "home/Library/Logs/DiagnosticReports/": 5,
                "home/Library/": 4, "Library/": 3, "var/": 3, "receipts/": 2,
            ].filter { path.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }!.value
            return parts.prefix(depth).joined(separator: "/")
        })
        #expect(rel == tops.union(["home/Library/LaunchAgents/com.example.Leftie.agent.plist", "Library/LaunchDaemons/updater.plist"]))
        #expect(found.first { $0.url.lastPathComponent == "Leftie" && $0.url.path.contains("Caches") }?.matchedByName == true)
        #expect(found.first { $0.url.lastPathComponent == "com.example.Leftie.plist" }?.matchedByName == false)
        #expect(found.first { $0.url.lastPathComponent == "data.db" } == nil)
        #expect(found.allSatisfy { !$0.needsAdmin && $0.sharedWith == nil && $0.size > 0 })
    }

    @Test func pluginBundlesAreMatchedByTheirOwnID() throws {
        let box = try Box()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let lib = box.home.appendingPathComponent("Library")
        try Box.bundle(at: lib.appendingPathComponent("QuickLook/Preview.qlgenerator"), id: "com.example.Leftie.ql",
                       name: "Preview", executable: "Preview")
        try Box.bundle(at: box.system.appendingPathComponent("Audio/Plug-Ins/Components/Verb.component"),
                       id: "com.example.Leftie.verb", name: "Verb", executable: "Verb")
        try Box.bundle(at: box.system.appendingPathComponent("Extensions/Driver.kext"), id: "com.example.Leftie.driver",
                       name: "Driver", executable: "Driver")
        try Box.bundle(at: box.system.appendingPathComponent("Audio/Plug-Ins/Components/Other.component"),
                       id: "com.other.verb", name: "Other", executable: "Other")
        try box.file(box.system, "StartupItems/Leftie/Leftie")
        try box.file(lib, "Caches/com.apple.nsurlsessiond/Downloads/com.example.Leftie/part")
        let identity = try #require(AppIdentity.read(appAt: box.app))
        let names = Set(AppLeftoverFinder(roots: box.roots).find(for: identity).map(\.url.lastPathComponent))
        #expect(names == ["Preview.qlgenerator", "Verb.component", "Driver.kext", "Leftie", "com.example.Leftie"])
    }

    /// A package receipt whose BOM (made with mkbom) lists the app and files elsewhere.
    func makePackage(_ box: Box, id: String, files: [String], dirs: [String] = []) throws {
        let stage = box.root.appendingPathComponent("stage-\(id)")
        for d in dirs { try FileManager.default.createDirectory(at: stage.appendingPathComponent(d), withIntermediateDirectories: true) }
        for f in files { try box.file(stage, f) }
        try FileManager.default.createDirectory(at: box.receipts, withIntermediateDirectories: true)
        let mkbom = Process()
        mkbom.executableURL = URL(fileURLWithPath: "/usr/bin/mkbom")
        mkbom.arguments = [stage.path, box.receipts.appendingPathComponent("\(id).bom").path]
        try mkbom.run()
        mkbom.waitUntilExit()
        #expect(mkbom.terminationStatus == 0)
        try box.plist(box.receipts, "\(id).plist", ["PackageIdentifier": id, "InstallPrefixPath": "/"])
        try FileManager.default.removeItem(at: stage)
    }

    @Test func packageReceiptsAndWhatThePackageInstalled() throws {
        let box = try Box()
        defer { try? FileManager.default.removeItem(at: box.root) }
        var roots = box.roots
        roots.volume = box.root
        let appFiles = ["Apps/Leftie.app/Contents/Info.plist"]
        let pkgFiles = appFiles + [
            "usr/local/bin/leftie",
            "Library/Audio/Plug-Ins/Components/Verb.component/Contents/Info.plist",
            "Library/Application Support/Acme/settings.json",
            "Library/Application Support/Leftie/data/a.db",
            "Library/LaunchDaemons/net.acme.helper.plist",
            "usr/lib/libleftie.dylib",
        ]
        try makePackage(box, id: "net.acme.leftie.pkg", files: pkgFiles)
        // What is on disk now: the package's files (one already gone), plus other software's files
        // in the same folders.
        for f in pkgFiles.dropFirst() where f != "Library/LaunchDaemons/net.acme.helper.plist" { try box.file(box.root, f) }
        try box.file(box.root, "usr/local/bin/other-tool")
        try box.file(box.root, "Library/Application Support/Acme/other-product.json")
        // A package that does not contain the app.
        try makePackage(box, id: "net.acme.unrelated", files: ["usr/local/bin/unrelated"])
        try box.file(box.root, "usr/local/bin/unrelated")

        let identity = try #require(AppIdentity.read(appAt: box.app))
        let found = AppLeftoverFinder(roots: roots).find(for: identity)
        let rel = Set(found.map { String($0.url.standardizedFileURL.path.dropFirst(box.root.standardizedFileURL.path.count + 1)) })
        #expect(rel == [
            "receipts/net.acme.leftie.pkg.plist", "receipts/net.acme.leftie.pkg.bom",
            "usr/local/bin/leftie",
            "Library/Audio/Plug-Ins/Components/Verb.component",
            "Library/Application Support/Acme/settings.json",
            "Library/Application Support/Leftie",
        ])
        #expect(found.first { $0.url.lastPathComponent == "leftie" }?.kind == "Installed by package net.acme.leftie.pkg")
        #expect(found.allSatisfy { $0.sharedWith == nil })
    }

    @Test func aPackageThatAlsoInstalledAnotherAppIsShared() throws {
        let box = try Box()
        defer { try? FileManager.default.removeItem(at: box.root) }
        var roots = box.roots
        roots.volume = box.root
        try makePackage(box, id: "net.acme.suite", files: [
            "Apps/Leftie.app/Contents/Info.plist", "Apps/Other.app/Contents/Info.plist", "usr/local/bin/suite",
        ])
        try box.file(box.root, "Apps/Other.app/Contents/Info.plist")
        try box.file(box.root, "usr/local/bin/suite")
        let identity = try #require(AppIdentity.read(appAt: box.app))
        let found = AppLeftoverFinder(roots: roots).find(for: identity).filter { !$0.url.path.contains("/Apps/") }
        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.sharedWith == "Other" })
    }
}
