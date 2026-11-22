import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilUI

/// Large-directory benchmark. Runs only when BASIL_PERF_DIR points at a big directory, e.g.:
///   mkdir -p /tmp/big && (cd /tmp/big && seq 200000 | sed 's/^/file /' | xargs -I{} touch "{}")
///   BASIL_PERF_DIR=/tmp/big swift test -c release --package-path Packages/BasilUI --filter largeDirectory
@MainActor
@Suite struct PaneModelPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_PERF_DIR"] != nil))
    func largeDirectoryLoadsSortsAndFilters() async throws {
        let dir = VFSPath.local(ProcessInfo.processInfo.environment["BASIL_PERF_DIR"]!)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let model = PaneModel(registry: registry, directory: dir)

        func waitForReload(_ action: () -> Void) async -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                var resumed = false
                model.onEvent = { event in
                    if case .reloaded = event, !resumed { resumed = true; c.resume() }
                }
                action()
            }
            return clock.now - start
        }

        let load = await waitForReload { model.load(dir) }
        print("PERF load+sort \(model.rows.count) items: \(load)")
        let sort = await waitForReload { model.setSortOrder(ListSortOrder(key: .size, ascending: false), cursor: nil) }
        print("PERF resort by size: \(sort)")
        let filter = await waitForReload { model.setFilter(try? NameFilter("*1234*"), cursor: nil) }
        print("PERF filter: \(filter) -> \(model.rows.count) rows")
        model.stop()
    }
}

@MainActor
@Suite struct PaneModelWatchTests {
    func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The start folder is watched too (it is loaded without a "directory change"), and both
    /// creations and removals show up.
    @Test func startFolderPicksUpCreatedAndRemovedFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-pane-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url.appendingPathComponent("a.txt"))
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let dir = VFSPath.local(url.path)
        let model = PaneModel(registry: registry, directory: dir)
        model.load(dir)
        #expect(await poll { model.rows.map(\.name) == ["a.txt"] })
        try await Task.sleep(for: .milliseconds(300))
        try Data().write(to: url.appendingPathComponent("b.txt"))
        #expect(await poll { model.rows.map(\.name) == ["a.txt", "b.txt"] }, "\(model.rows.map(\.name))")
        try FileManager.default.moveItem(at: url.appendingPathComponent("b.txt"), to: url.appendingPathComponent("c.txt"))
        #expect(await poll { model.rows.map(\.name) == ["a.txt", "c.txt"] }, "\(model.rows.map(\.name))")
        model.reload(cursor: nil)
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: url.appendingPathComponent("c.txt"))
        #expect(await poll { model.rows.map(\.name) == ["a.txt"] }, "\(model.rows.map(\.name))")
        model.stop()
    }
}

/// Total Commander's numpad selection: groups, same extension, invert, restore.
@MainActor
@Suite struct PaneSelectionTests {
    func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func groupsInvertAndRestore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-select-\(UUID())")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Music.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for name in ["a.mp3", "b.MP3", "c.flac", "d.txt", "readme"] {
            try Data().write(to: url.appendingPathComponent(name))
        }
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let dir = VFSPath.local(url.path)
        let model = PaneModel(registry: registry, directory: dir)
        model.load(dir)
        #expect(await poll { model.rows.count == 6 })
        func names() -> [String] { model.selectedItems.map(\.name).sorted() }

        #expect(model.setSelection(true, matching: try NameFilter("*.mp3;*.flac"), includeFolders: false) == 3)
        #expect(names() == ["a.mp3", "b.MP3", "c.flac"])
        #expect(model.setSelection(false, matching: try NameFilter("*.flac"), includeFolders: false) == 1)
        #expect(names() == ["a.mp3", "b.MP3"])
        // Folders count only when asked for.
        #expect(model.setSelection(true, matching: try NameFilter("*.d"), includeFolders: false) == 0)
        #expect(model.setSelection(true, matching: try NameFilter("*.d"), includeFolders: true) == 1)
        #expect(names() == ["Music.d", "a.mp3", "b.MP3"])

        // Invert touches files only.
        model.invertSelection()
        #expect(names() == ["Music.d", "c.flac", "d.txt", "readme"])

        // Same extension, without case; a file without one matches files without one.
        model.deselectAll()
        #expect(model.setSelection(true, extension: "mp3") == 2)
        #expect(model.setSelection(true, extension: "") == 1)
        #expect(names() == ["a.mp3", "b.MP3", "readme"])
        #expect(model.setSelection(false, extension: "MP3") == 2)
        #expect(names() == ["readme"])

        // Num/ brings back what was selected before the last bulk change.
        model.deselectAll()
        #expect(names().isEmpty)
        model.restoreSelection()
        #expect(names() == ["readme"])
        model.stop()
    }
}
