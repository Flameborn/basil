import BasilCore
import BasilVFS
import Foundation

/// State of one file pane: directory, sorted listing, visible rows (after hidden/filter),
/// selection and the cursor. Heavy work (listing, sorting, filtering) runs off the main actor.
@MainActor
final class PaneModel {
    enum Event {
        /// Rows were replaced. `cursor` is the path the cursor should land on, if any.
        case reloaded(cursor: VFSPath?)
        case selectionChanged
        case loadingChanged
        case failed(Error)
    }

    let registry: ProviderRegistry
    var onEvent: ((Event) -> Void)?

    private(set) var directory: VFSPath
    private(set) var allItems: [FileItem] = []
    /// The visible items (after hidden/filter). There is no ".." row: Backspace goes up.
    private(set) var rows: [FileItem] = []
    private(set) var selected: Set<VFSPath> = []
    private(set) var isLoading = false
    private(set) var sortOrder = ListSortOrder.default
    private(set) var showHidden = false
    private(set) var filter: NameFilter?
    /// Calculated folder sizes (Cmd+Shift+S), kept until the pane shows another folder.
    private var folderSizes: [VFSPath: Int64] = [:]

    private var generation = 0
    /// Incremented per rows rebuild; only the newest rebuild is applied (filter keystrokes race otherwise).
    private var rowsGeneration = 0
    /// The cursor a load asked for, until its rows are shown. A rebuild that starts meanwhile (a watcher
    /// refresh, a sort) only knows the cursor in the old rows, so it lands on this one instead.
    private var pendingLoadCursor: VFSPath??
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var pendingChanges: Set<VFSPath> = []
    private var pendingReloadAll = false
    private var flushScheduled = false

    /// Above this many changes in one burst, re-list instead of patching item by item.
    private let incrementalLimit = 500

    init(registry: ProviderRegistry, directory: VFSPath) {
        self.registry = registry
        self.directory = directory
    }

    var selectedItems: [FileItem] { allItems.filter { selected.contains($0.path) } }

    // MARK: Loading

    /// Loads `target`. On failure the pane stays where it was and `.failed` is emitted.
    func load(_ target: VFSPath, cursor: VFSPath? = nil, keepState: Bool = false) {
        let provider: any FileSystemProvider
        do { provider = try registry.provider(for: target.location) } catch {
            onEvent?(.failed(error))
            return
        }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        isLoading = true
        onEvent?(.loadingChanged)

        let order = sortOrder
        loadTask = Task { [weak self] in
            do {
                var items: [FileItem] = []
                for try await batch in provider.list(target) {
                    try Task.checkCancellation()
                    items += batch
                }
                if let self, target == self.directory { items = self.withFolderSizes(items) }
                let sorted = await Task.detached(priority: .userInitiated) { ItemSorter.sorted(items, by: order) }.value
                guard let self, gen == self.generation else { return }
                let changedDirectory = target != self.directory
                self.directory = target
                self.allItems = sorted
                if changedDirectory {
                    self.selected = []
                    self.folderSizes = [:]
                    self.filter = nil // Quick filter is cleared on directory change.
                } else if !keepState {
                    self.selected = self.selected.intersection(sorted.map(\.path))
                }
                // The start folder is never a "change", so it is also watched when nothing is yet.
                if changedDirectory || self.watchTask == nil { self.startWatching(provider) }
                self.pendingLoadCursor = .some(cursor)
                await self.rebuildRows(cursor: cursor)
                self.isLoading = false
                self.onEvent?(.loadingChanged)
            } catch is CancellationError {
            } catch {
                guard let self, gen == self.generation else { return }
                self.isLoading = false
                self.onEvent?(.loadingChanged)
                self.onEvent?(.failed(error))
            }
        }
    }

    func reload(cursor: VFSPath?) { load(directory, cursor: cursor, keepState: true) }

    // MARK: Sorting / filtering / hidden

    func setSortOrder(_ order: ListSortOrder, cursor: VFSPath?) {
        sortOrder = order
        let items = allItems
        let gen = generation
        Task {
            let sorted = await Task.detached(priority: .userInitiated) { ItemSorter.sorted(items, by: order) }.value
            // Drop stale results: a newer sort or a reload happened meanwhile.
            guard gen == generation, order == sortOrder else { return }
            allItems = sorted
            await rebuildRows(cursor: cursor)
        }
    }

    func setShowHidden(_ show: Bool, cursor: VFSPath?) {
        showHidden = show
        Task { await rebuildRows(cursor: cursor) }
    }

    func setFilter(_ newFilter: NameFilter?, cursor: VFSPath?) {
        filter = newFilter?.isEmpty == true ? nil : newFilter
        Task { await rebuildRows(cursor: cursor) }
    }

    private func rebuildRows(cursor: VFSPath?) async {
        let items = allItems
        let showHidden = showHidden
        let filter = filter
        let gen = generation
        rowsGeneration += 1
        let rowsGen = rowsGeneration
        let cursor = pendingLoadCursor ?? cursor
        let rows = await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            items.filter { (showHidden || !$0.isHidden) && (filter?.matches($0.name) ?? true) }
        }.value
        guard gen == generation, rowsGen == rowsGeneration else { return }
        pendingLoadCursor = nil
        self.rows = rows
        onEvent?(.reloaded(cursor: cursor))
    }

    // MARK: Folder sizes

    private func withFolderSizes(_ items: [FileItem]) -> [FileItem] {
        guard !folderSizes.isEmpty else { return items }
        return items.map { item in folderSizes[item.path].map(item.withSize) ?? item }
    }

    /// Calculates the recursive size of each folder (one after another), then shows the sizes in
    /// the Size column. Cancelling the calling task stops the walk. Results for a folder the pane
    /// has left meanwhile are dropped (the returned totals are still correct).
    func calculateSizes(of folders: [VFSPath]) async throws -> [VFSPath: DirectoryTotals] {
        let provider = try registry.provider(for: directory.location)
        let start = directory
        var results: [VFSPath: DirectoryTotals] = [:]
        for folder in folders {
            // Detached so the walk never runs on the main actor; cancellation is passed on by hand.
            let walk = Task.detached(priority: .userInitiated) { try await provider.totals(of: folder) }
            results[folder] = try await withTaskCancellationHandler { try await walk.value } onCancel: { walk.cancel() }
        }
        guard start == directory else { return results }
        for (path, totals) in results { folderSizes[path] = totals.bytes }
        let items = withFolderSizes(allItems)
        let order = sortOrder
        let gen = generation
        let sorted = await Task.detached(priority: .userInitiated) { ItemSorter.sorted(items, by: order) }.value
        guard gen == generation, order == sortOrder else { return results }
        allItems = sorted
        await rebuildRows(cursor: currentCursorProvider?())
        return results
    }

    // MARK: Marks

    func toggleSelection(_ path: VFSPath) {
        if selected.remove(path) == nil { selected.insert(path) }
        onEvent?(.selectionChanged)
    }

    func selectAllFiles() {
        for item in rows where !item.isDirectoryLike { selected.insert(item.path) }
        onEvent?(.selectionChanged)
    }

    func deselectAll() {
        selected.removeAll()
        onEvent?(.selectionChanged)
    }

    // MARK: Watching

    private func startWatching(_ provider: any FileSystemProvider) {
        watchTask?.cancel()
        pendingChanges.removeAll()
        pendingReloadAll = false
        guard let stream = provider.watch(directory) else { return }
        let watched = directory
        watchTask = Task { [weak self] in
            for await change in stream {
                guard let self, self.directory == watched else { return }
                switch change {
                case .reloadAll: self.pendingReloadAll = true
                case .item(let path): self.pendingChanges.insert(path)
                }
                self.scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            flushScheduled = false
            await flushChanges()
        }
    }

    /// Applies watcher changes as a diff against the current listing; the cursor stays on the same path.
    private func flushChanges() async {
        let cursorHint = currentCursorProvider?()
        if pendingReloadAll || pendingChanges.count > incrementalLimit {
            pendingReloadAll = false
            pendingChanges.removeAll()
            reload(cursor: cursorHint)
            return
        }
        let changes = pendingChanges
        pendingChanges.removeAll()
        guard !changes.isEmpty, let provider = try? registry.provider(for: directory.location) else { return }

        var updated: [VFSPath: FileItem?] = [:]
        for path in changes {
            // updateValue, not subscript assignment: assigning nil would drop the key, and a
            // removed item must stay in the map as "gone" (.some(nil)).
            let item = try? await provider.item(at: path)
            updated.updateValue(item, forKey: path)
        }
        for (path, item) in updated {
            if let item { updated[path] = withFolderSizes([item]).first } else { folderSizes[path] = nil }
        }
        let order = sortOrder
        let items = allItems
        let changed = updated
        let patched = await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            var result = items.filter { changed[$0.path] == nil }
            for case .some(let item) in changed.values {
                result.insert(item, at: ItemSorter.insertionIndex(of: item, in: result, by: order))
            }
            return result
        }.value
        allItems = patched
        selected = selected.filter { path in updated[path] == nil || updated[path]! != nil }
        await rebuildRows(cursor: cursorHint)
    }

    /// Set by the view so watcher-driven refreshes keep the cursor on the same item.
    var currentCursorProvider: (() -> VFSPath?)?

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
    }
}
