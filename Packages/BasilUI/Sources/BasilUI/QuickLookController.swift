import AppKit
import BasilCore
import Quartz

/// F3: the Quick Look panel for the selected items, or the cursor item when nothing is selected.
/// While the panel is open, keys go to the pane (Up/Down move the cursor, F3 or Escape close),
/// and the preview follows the cursor, like Finder. The name of each newly previewed item is
/// announced, because VoiceOver is in the panel and does not read the pane's cursor row.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private weak var pane: PaneViewController?
    private var announced: URL?
    var announce: (String) -> Void = { _ in }

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(for pane: PaneViewController) {
        if isOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        self.pane = pane
        guard update() else {
            let hasItems = !pane.model.selectedItems.isEmpty || pane.cursorItem != nil
            return announce(hasItems ? "Only local files can be viewed for now" : "No items")
        }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// The pane's cursor, selection or active side changed.
    func paneChanged(_ pane: PaneViewController) {
        guard isOpen else { return }
        self.pane = pane
        update()
    }

    /// Rebuilds the item list from the pane. Returns false when there is nothing local to show.
    @discardableResult
    private func update() -> Bool {
        guard let pane else { return false }
        let selected = pane.model.selectedItems
        let source = selected.isEmpty ? (pane.cursorItem.map { [$0] } ?? []) : selected
        let newURLs = source.filter { $0.path.location == .local }.map { URL(fileURLWithPath: $0.path.path) }
        guard !newURLs.isEmpty else { return false }
        let cursorURL = pane.cursorItem.map { URL(fileURLWithPath: $0.path.path) }
        let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
        let oldIndex = panel?.currentPreviewItemIndex ?? 0
        let changed = newURLs != urls
        urls = newURLs
        let index = cursorURL.flatMap { urls.firstIndex(of: $0) } ?? (changed ? 0 : min(oldIndex, urls.count - 1))
        if let panel, panel.isVisible {
            if changed { panel.reloadData() }
            if panel.currentPreviewItemIndex != index { panel.currentPreviewItemIndex = index }
            announceIfNew(urls[index])
        } else {
            announced = urls[index]
            panel?.currentPreviewItemIndex = index
        }
        return true
    }

    private func announceIfNew(_ url: URL) {
        guard url != announced else { return }
        announced = url
        announce(url.lastPathComponent)
    }

    // MARK: Panel control (called by PaneTableView, which is in the responder chain)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let current = announced, let i = urls.firstIndex(of: current) { panel.currentPreviewItemIndex = i }
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        announced = nil
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    // MARK: QLPreviewPanelDelegate

    /// Keys go to the pane, except Escape, which closes the panel.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode != 53, let pane else { return false }
        pane.tableView.keyDown(with: event)
        return true
    }
}
