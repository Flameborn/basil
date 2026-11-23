import CryptoKit
import Foundation
import Testing
@testable import BasilIntegrations

@Suite struct AppUpdaterTests {
    @Test func versionsCompareByParts() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("0.1.0") < v("0.1.1"))
        #expect(try v("0.9.0") < v("0.10.0"))
        #expect(try v("v1.2") == v("1.2.0"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try v("V2.0.1").description == "2.0.1")
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    static func release(tag: String = "v0.2.0", prerelease: Bool = false, draft: Bool = false,
                        assets: String? = nil) -> Data {
        let list = assets ?? """
            [{"name": "notes.txt", "browser_download_url": "https://example.com/n", "size": 3},
             {"name": "Basil-0.2.0.dmg", "browser_download_url": "https://example.com/Basil-0.2.0.dmg",
              "size": 1234, "digest": "sha256:ABCDEF"}]
            """
        return Data("""
            {"tag_name": "\(tag)", "name": "Basil 0.2.0", "body": "## Added\\n- Updates\\n- **Bold** `code`",
             "html_url": "https://github.com/Flameborn/basil/releases/tag/v0.2.0",
             "draft": \(draft), "prerelease": \(prerelease), "assets": \(list)}
            """.utf8)
    }

    @Test func parsesTheLatestRelease() throws {
        let update = try #require(try UpdateFeed.parse(Self.release()))
        #expect(update.version == AppVersion("0.2.0"))
        #expect(update.title == "Basil 0.2.0")
        #expect(update.dmgName == "Basil-0.2.0.dmg")
        #expect(update.dmgSize == 1234)
        #expect(update.sha256 == "abcdef")
        #expect(update.plainNotes == "Added\nUpdates\nBold code")
    }

    @Test func skipsPreReleasesDraftsAndReleasesWithoutDMG() throws {
        #expect(try UpdateFeed.parse(Self.release(prerelease: true)) == nil)
        #expect(try UpdateFeed.parse(Self.release(draft: true)) == nil)
        #expect(try UpdateFeed.parse(Self.release(tag: "nightly")) == nil)
        #expect(try UpdateFeed.parse(Self.release(assets: "[]")) == nil)
        #expect(throws: UpdateError.badAnswer) { try UpdateFeed.parse(Data("{}".utf8)) }
    }

    @Test func feedURL() {
        #expect(UpdateFeed.basil.latestURL.absoluteString == "https://api.github.com/repos/Flameborn/basil/releases/latest")
    }

    @Test func checksSizeAndDigest() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.dmg")
        let data = Data("hello update".utf8)
        try data.write(to: file)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try UpdateInstaller.check(file, size: data.count, sha256: hex.uppercased())
        try UpdateInstaller.check(file, size: data.count, sha256: nil)
        #expect(throws: UpdateError.sizeMismatch(expected: 3, got: data.count)) {
            try UpdateInstaller.check(file, size: 3, sha256: hex)
        }
        #expect(throws: UpdateError.digestMismatch) {
            try UpdateInstaller.check(file, size: data.count, sha256: String(repeating: "0", count: 64))
        }
    }

    // MARK: - Staging and installing from a real DMG

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func sh(_ tool: String, _ args: [String]) throws -> String {
        let result = try UpdateInstaller.run(tool, args)
        guard result.status == 0 else { throw UpdateError.installFailed("\(tool) \(args): \(result.output)") }
        return result.output
    }

    /// A minimal app bundle signed ad hoc with `identifier`.
    static func makeApp(at url: URL, identifier: String, version: String) throws {
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                    "CFBundleVersion": "1", "CFBundleExecutable": "Basil", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("Basil").path)
        try sh("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path])
    }

    static func makeDMG(with app: URL, at dmg: URL) throws {
        let stage = dmg.deletingPathExtension().appendingPathExtension("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try sh("/usr/bin/ditto", [app.path, stage.appendingPathComponent("Basil.app").path])
        try sh("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Basil test", "-srcfolder", stage.path,
                                    "-fs", "HFS+", "-format", "ULFO", dmg.path])
    }

    static let id = "com.flameborn.basil.updatetest"

    @Test func stagesVerifiesAndSwapsTheApp() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Basil.app")
        try Self.makeApp(at: installed, identifier: Self.id, version: "0.1.0")
        let newApp = root.appendingPathComponent("new/Basil.app")
        try Self.makeApp(at: newApp, identifier: Self.id, version: "0.2.0")
        let dmg = root.appendingPathComponent("Basil-0.2.0.dmg")
        try Self.makeDMG(with: newApp, at: dmg)

        let installer = UpdateInstaller(installedApp: installed, scratch: root.appendingPathComponent("scratch"),
                                        requirement: "identifier \"\(Self.id)\"", bundleID: Self.id)
        let staged = try installer.stage(dmg, version: AppVersion("0.2.0")!)
        #expect(staged.deletingLastPathComponent() == installed.deletingLastPathComponent())
        try installer.install(staged)
        let version = Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String
        #expect(version == "0.2.0")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(left == ["Basil.app"])
    }

    @Test func refusesAnAppSignedDifferently() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Basil.app")
        try Self.makeApp(at: installed, identifier: Self.id, version: "0.1.0")
        let newApp = root.appendingPathComponent("new/Basil.app")
        try Self.makeApp(at: newApp, identifier: Self.id, version: "0.2.0")
        let dmg = root.appendingPathComponent("Basil-0.2.0.dmg")
        try Self.makeDMG(with: newApp, at: dmg)

        // Same bundle ID, but the signature must come from a certificate it does not have.
        let installer = UpdateInstaller(installedApp: installed, scratch: root.appendingPathComponent("scratch"),
                                        requirement: "identifier \"\(Self.id)\" and anchor apple generic",
                                        bundleID: Self.id)
        #expect(throws: UpdateError.self) { try installer.stage(dmg, version: AppVersion("0.2.0")!) }
        // Nothing was left next to the installed app, which is unchanged.
        let left = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(left == ["Basil.app"])
        #expect(Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String == "0.1.0")
    }

    @Test func refusesAnotherVersionOrApp() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Basil.app")
        try Self.makeApp(at: installed, identifier: Self.id, version: "0.1.0")
        let other = root.appendingPathComponent("other/Basil.app")
        try Self.makeApp(at: other, identifier: "com.example.other", version: "0.2.0")
        let dmg = root.appendingPathComponent("other.dmg")
        try Self.makeDMG(with: other, at: dmg)
        let installer = UpdateInstaller(installedApp: installed, scratch: root.appendingPathComponent("scratch"),
                                        requirement: "identifier \"\(Self.id)\"", bundleID: Self.id)
        #expect(throws: UpdateError.wrongApp("identifier com.example.other, expected \(Self.id)")) {
            try installer.stage(dmg, version: AppVersion("0.2.0")!)
        }
        let same = root.appendingPathComponent("same/Basil.app")
        try Self.makeApp(at: same, identifier: Self.id, version: "0.1.5")
        let dmg2 = root.appendingPathComponent("same.dmg")
        try Self.makeDMG(with: same, at: dmg2)
        #expect(throws: UpdateError.wrongApp("version 0.1.5, expected 0.2.0")) {
            try installer.stage(dmg2, version: AppVersion("0.2.0")!)
        }
    }
}

/// Against the real repository (skipped unless BASIL_UPDATE_LIVE=1): the latest release is
/// found, its DMG downloads and matches GitHub's digest, and its app satisfies the requirement
/// in BASIL_UPDATE_REQUIREMENT (for example `codesign -d -r- Basil.app`'s designated line).
@Suite struct AppUpdaterLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_UPDATE_LIVE"] == "1"))
    func downloadsAndChecksTheLatestRelease() async throws {
        let update = try #require(try await UpdateFeed.basil.latest())
        #expect(update.sha256 != nil)
        let root = try AppUpdaterTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Basil.app")
        try AppUpdaterTests.makeApp(at: installed, identifier: "com.flameborn.basil", version: "0.0.1")
        let installer = UpdateInstaller(installedApp: installed, scratch: root.appendingPathComponent("scratch"),
                                        requirement: ProcessInfo.processInfo.environment["BASIL_UPDATE_REQUIREMENT"],
                                        bundleID: "com.flameborn.basil")
        let dmg = try await installer.download(update)
        let staged = try installer.stage(dmg, version: update.version)
        try installer.install(staged)
        #expect(Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String == update.version.description)
    }
}
