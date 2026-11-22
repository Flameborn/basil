import AppKit
import BasilCore
import Quartz

/// F3: the Quick Look panel for the selected items, or the cursor item when nothing is selected.
/// While the panel is open, keys go to the pane (Up/Down move the cursor, F3 or Escape close),
/// and the preview follows the cursor, like Finder. The name of each newly previewed item is
/// announced, because VoiceOver is in the panel and does not read the pane's cursor row.
///
/// Files inside archives are extracted into `TemporaryCopies` when the preview reaches them;
/// the panel shows the file once its copy is ready.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// One previewed file. `url` stays nil until a copy of a file inside an archive is ready.
    final class Item: NSObject, QLPreviewItem {
        let file: FileItem
        var url: URL?
        var failed = false
        init(_ file: FileItem, url: URL?) {
            self.file = file
            self.url = url
        }
        var previewItemURL: URL? { url }
        var previewItemTitle: String? { file.name }
    }

    private var items: [Item] = []
    private weak var pane: PaneViewController?
    private var announced: VFSPath?
    var announce: (String) -> Void = { _ in }
    var copies: TemporaryCopies?

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(for pane: PaneViewController) {
        if isOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        self.pane = pane
        guard update() else {
            let hasItems = !pane.model.selectedItems.isEmpty || pane.cursorItem != nil
            return announce(hasItems ? "Folders cannot be viewed" : "No items")
        }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// The pane's cursor, selection or active side changed.
    func paneChanged(_ pane: PaneViewController) {
        guard isOpen else { return }
        self.pane = pane
        update()
    }

    /// Rebuilds the item list from the pane. Returns false when there is nothing to show.
    @discardableResult
    private func update() -> Bool {
        guard let pane else { return false }
        let selected = pane.model.selectedItems
        let source = selected.isEmpty ? (pane.cursorItem.map { [$0] } ?? []) : selected
        // Folders inside archives have no local copy to preview; local folders do.
        let files = source.filter { $0.path.location == .local || !$0.isDirectoryLike }
        guard !files.isEmpty else { return false }
        let changed = files.map(\.path) != items.map(\.file.path)
        if changed {
            let old = Dictionary(items.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
            items = files.map { file in
                if let reused = old[file.path], reused.file.size == file.size, reused.file.modified == file.modified { return reused }
                return Item(file, url: copies?.preview(of: file).map { URL(fileURLWithPath: $0.path) })
            }
        }
        let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
        let oldIndex = panel?.currentPreviewItemIndex ?? 0
        let cursor = pane.cursorItem?.path
        let index = cursor.flatMap { c in items.firstIndex { $0.file.path == c } } ?? (changed ? 0 : min(oldIndex, items.count - 1))
        if let panel, panel.isVisible {
            if changed { panel.reloadData() }
            if panel.currentPreviewItemIndex != index { panel.currentPreviewItemIndex = index }
            announceIfNew(items[index])
        } else {
            announced = items[index].file.path
            panel?.currentPreviewItemIndex = index
        }
        return true
    }

    private func announceIfNew(_ item: Item) {
        guard item.file.path != announced else { return }
        announced = item.file.path
        announce(item.file.name)
    }

    /// Starts extracting a file inside an archive; the panel refreshes when the copy is ready.
    private func prepare(_ item: Item) {
        guard item.url == nil, !item.failed, let copies else { return }
        Task {
            do {
                let copy = try await copies.extractPreview(of: item.file)
                item.url = URL(fileURLWithPath: copy.path)
            } catch is CancellationError {
                return
            } catch {
                item.failed = true
                announce("Could not extract \(item.file.name): \(error.localizedDescription)")
            }
            guard isOpen, items.contains(where: { $0 === item }) else { return }
            guard let panel = QLPreviewPanel.shared() else { return }
            if let current = panel.currentPreviewItem as? Item, current === item { panel.refreshCurrentPreviewItem() }
        }
    }

    // MARK: Panel control (called by PaneTableView, which is in the responder chain)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let current = announced, let i = items.firstIndex(where: { $0.file.path == current }) {
            panel.currentPreviewItemIndex = i
        }
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        announced = nil
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        prepare(items[index])
        return items[index]
    }

    // MARK: QLPreviewPanelDelegate

    /// Keys go to the pane, except Escape, which closes the panel.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode != 53, let pane else { return false }
        pane.tableView.keyDown(with: event)
        return true
    }
}
