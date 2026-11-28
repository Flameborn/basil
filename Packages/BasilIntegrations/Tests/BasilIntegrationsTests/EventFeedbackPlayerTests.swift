import AppKit
import BasilCore
import Foundation
import Testing
@testable import BasilIntegrations

@MainActor
@Suite struct EventFeedbackPlayerTests {
    @Test func discoversAlertNamesAndNestedSystemSoundFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basil-sounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            return url
        }
        _ = try file("alerts/Glass.aiff")
        _ = try file("user/Glass.wav")
        _ = try file("user/Custom.MP3")
        _ = try file("alerts/nested/ignored.aif")
        _ = try file("system/finder/readme.txt")
        let trash = try file("system/dock/drag to trash.aif")
        let empty = try file("system/finder/empty trash.aif")
        let mount = try file("system/system/Volume Mount.aif")
        let glass = try file("system/system/Glass.wav")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("system/folder.aif"), withIntermediateDirectories: true)
        let sounds = EventFeedbackPlayer.availableSounds(
            alertFolders: ["alerts", "user", "missing"].map { root.appendingPathComponent($0) },
            systemFolder: root.appendingPathComponent("system"))
        #expect(Set(sounds.compactMap { sound -> String? in
            if case .system(let name) = sound { return name }; return nil
        }) == ["Glass", "Custom"])
        // Directory enumeration may return /private/var where temporaryDirectory uses /var.
        let paths = sounds.compactMap { sound -> String? in
            if case .file(let path) = sound { return path }; return nil
        }
        for url in [trash, empty, mount, glass] {
            let expectedID = try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            #expect(paths.contains { path in
                let id = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
                return expectedID != nil && id == expectedID
            })
        }
        #expect(sounds.count == 6)
        #expect(sounds.map(\.title) == sounds.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(EventFeedbackPlayer.availableSounds(alertFolders: [], systemFolder: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func finderDefaultsAreListedAndLoadable() {
        let sounds = EventFeedbackPlayer.availableSounds()
        for sound in [SystemSoundFiles.volumeMount, SystemSoundFiles.dragToTrash, SystemSoundFiles.emptyTrash] {
            #expect(sounds.contains(sound))
            guard case .file(let path) = sound else { Issue.record("Finder sounds must be file-backed"); continue }
            #expect(NSSound(contentsOfFile: path, byReference: true) != nil)
        }
        #expect(sounds.contains(.system("Glass")))
    }
}
