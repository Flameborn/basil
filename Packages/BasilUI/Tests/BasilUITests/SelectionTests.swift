import AppKit
import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilUI

@MainActor
@Suite final class SelectionTests {
    let root: URL
    let model: PaneModel

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("basil-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.mp3", ".hidden"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        model = PaneModel(registry: registry, directory: .local(root.path))
        model.load(.local(root.path))
        try #require(await poll { self.model.rows.count == 4 })
        model.stop()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private var names: Set<String> { Set(model.selectedItems.map(\.name)) }

    @Test func allFilesAndFoldersUseVisibleItemsAndKeepOtherSelections() async throws {
        model.selectAllFiles()
        #expect(names == ["a.txt", "b.txt", "c.mp3"])
        model.selectAllFolders()
        #expect(names == ["Folder", "a.txt", "b.txt", "c.mp3"])
        model.restoreSelection()
        #expect(names == ["a.txt", "b.txt", "c.mp3"])
        model.deselectAll()
        model.selectAllFolders()
        #expect(names == ["Folder"])
        model.selectAllFiles()
        #expect(names == ["Folder", "a.txt", "b.txt", "c.mp3"])

        model.deselectAll()
        model.setFilter(try NameFilter("*.txt"), cursor: nil)
        try #require(await poll { self.model.rows.count == 2 })
        model.selectAll()
        #expect(names == ["a.txt", "b.txt"])
        model.setFilter(nil, cursor: nil)
        try #require(await poll { self.model.rows.count == 4 })
        model.selectAll()
        #expect(names == ["Folder", "a.txt", "b.txt", "c.mp3"])
        model.restoreSelection()
        #expect(names == ["a.txt", "b.txt"])
    }

    @Test func rangesIncludeCursorAndKeepSelectionsOutsideRange() {
        model.toggleSelection(model.rows[3].path)
        model.selectRange(from: 1, to: 0)
        #expect(names == ["Folder", "a.txt", "c.mp3"])
        model.restoreSelection()
        #expect(names == ["c.mp3"])
        model.deselectAll()
        model.selectRange(from: 1, to: 3)
        #expect(names == ["a.txt", "b.txt", "c.mp3"])
        // Repeating selects; it never toggles the range off.
        model.selectRange(from: 1, to: 3)
        #expect(names == ["a.txt", "b.txt", "c.mp3"])
        model.deselectAll()
        model.selectRange(from: 0, to: 0)
        #expect(names == ["Folder"])
        model.deselectAll()
        model.selectRange(from: 3, to: 3)
        #expect(names == ["c.mp3"])
    }

    @Test func rangesFollowFilteredSortOrderAndIgnoreMissingCursor() async throws {
        model.setSortOrder(ListSortOrder(key: .name, ascending: false), cursor: nil)
        try #require(await poll { self.model.rows.last?.name == "a.txt" })
        model.setFilter(try NameFilter("*.txt"), cursor: nil)
        try #require(await poll { self.model.rows.map(\.name) == ["b.txt", "a.txt"] })
        model.selectRange(from: 1, to: 0)
        #expect(names == ["a.txt", "b.txt"])
        model.deselectAll()
        model.selectRange(from: -1, to: 0)
        model.selectRange(from: 0, to: 2)
        #expect(names.isEmpty)
        model.setFilter(try NameFilter("missing"), cursor: nil)
        try #require(await poll { self.model.rows.isEmpty })
        model.selectRange(from: 0, to: -1)
        model.selectAll()
        model.selectAllFolders()
        #expect(names.isEmpty)
    }

    @Test func registryCommandsUseActivePaneAndKeepRangesOutOfMenus() async throws {
        _ = NSApplication.shared
        let savesFrames = BasilWindows.savesFrames
        BasilWindows.savesFrames = false
        defer { BasilWindows.savesFrames = savesFrames }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("settings").path))
        let registry = CommandRegistry()
        let controller = MainWindowController(
            providers: model.registry, commands: registry, settings: SettingsStore(defaults: defaults),
            queue: FileOperationQueue(), defaults: defaults,
            startDirectories: (.local(root.path), .local(root.path)), dataDirectory: root,
            secrets: MemorySecretStore(), remoteSecrets: MemorySecretStore(),
            copiesDirectory: root.appendingPathComponent("copies"))
        defer {
            controller.left.model.stop()
            controller.right.model.stop()
            controller.close()
        }
        try #require(await poll { controller.left.model.rows.count == 4 && controller.right.model.rows.count == 4 })

        let expected: [(CommandID, [KeyChord])] = [
            ("select.all", [KeyChord(.character("a"), .command), KeyChord(.numpad("+"), .command)]),
            ("select.toStart", [KeyChord(.up, [.option, .shift]), KeyChord(.home, [.option, .shift])]),
            ("select.toEnd", [KeyChord(.down, [.option, .shift]), KeyChord(.end, [.option, .shift])]),
            ("select.group", [KeyChord(.character("="), .command), KeyChord(.numpad("+"))]),
            ("select.ungroup", [KeyChord(.character("-"), .command), KeyChord(.numpad("-"))]),
            ("select.invert", [KeyChord(.character("8"), [.command, .shift]), KeyChord(.numpad("*"))]),
            ("select.restore", [KeyChord(.character("/"), .command), KeyChord(.numpad("/"))]),
            ("select.sameExtension", [KeyChord(.character("="), .option), KeyChord(.numpad("+"), .option)]),
            ("select.deselectSameExtension", [KeyChord(.character("-"), .option), KeyChord(.numpad("-"), .option)]),
        ]
        for (id, chords) in expected {
            #expect(registry.command(id) != nil)
            #expect(Set(registry.chords(for: id)) == Set(chords))
            for chord in chords { #expect(registry.commandID(for: chord) == id) }
        }
        #expect(registry.chords(for: "select.allFiles").isEmpty)
        #expect(registry.chords(for: "select.allFolders").isEmpty)
        BuiltinMenus.register(in: registry.menus)
        let mark = try #require(registry.menus.menus.first { $0.title == "Mark" })
        let filesIndex = try #require(mark.items.firstIndex(of: .command("select.allFiles")))
        #expect(mark.items[filesIndex + 1] == .command("select.allFolders"))
        func commandIDs(_ nodes: [MenuNode]) -> [CommandID] {
            nodes.flatMap { node -> [CommandID] in
                switch node {
                case .command(let id): [id]
                case .submenu(_, let children): commandIDs(children)
                case .separator: []
                }
            }
        }
        let menuIDs = registry.menus.menus.flatMap { commandIDs($0.items) }
        #expect(menuIDs.contains("select.all"))
        #expect(!menuIDs.contains("select.toStart"))
        #expect(!menuIDs.contains("select.toEnd"))

        controller.setActive(.right)
        #expect(registry.perform(KeyChord(.character("a"), .command), in: controller))
        #expect(controller.right.model.selected.count == 4)
        #expect(controller.left.model.selected.isEmpty)
        let pane = controller.right
        for (id, selectedNames) in [("select.toStart", Set(["Folder", "a.txt"])),
                                    ("select.toEnd", Set(["a.txt", "b.txt", "c.mp3"]))] {
            for chord in registry.chords(for: CommandID(rawValue: id)) {
                pane.model.deselectAll()
                pane.moveCursor(to: 1)
                #expect(registry.perform(chord, in: controller))
                #expect(Set(pane.model.selectedItems.map(\.name)) == selectedNames)
                #expect(pane.cursorRow == 1)
            }
        }
        #expect(controller.left.model.selected.isEmpty)
    }
}
