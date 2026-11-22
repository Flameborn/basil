import AppKit
import BasilCore

/// Total Commander's numpad selection commands: Num+ / Num- select or deselect a group by mask,
/// Num* inverts, Num/ restores, Option+Num+ / Option+Num- work on the cursor file's extension.
extension MainWindowController {
    private static let maskHistoryKey = "selectGroup.history"
    private static let includeFoldersKey = "selectGroup.includeFolders"
    private static let maskHistoryLimit = 20

    /// Num+ (select) or Num- (deselect): asks for a mask in quick-filter syntax (`*.mp3;*.flac`,
    /// exclusions after `|`), then changes the matching items of the active pane.
    func selectGroup(_ select: Bool) {
        guard let window else { return }
        let pane = activePane
        Task {
            guard let answer = await askMask(in: window, select: select) else { return }
            guard let filter = try? NameFilter(answer.mask), !filter.isEmpty else { return }
            let changed = pane.model.setSelection(select, matching: filter, includeFolders: answer.includeFolders)
            announceSelection(in: pane, select: select, changed: changed)
        }
    }

    /// Option+Num+ / Option+Num-: all files with the cursor file's extension.
    func selectSameExtension(_ select: Bool) {
        let pane = activePane
        guard let item = pane.cursorItem, !item.isDirectoryLike else { return announce("No file") }
        let changed = pane.model.setSelection(select, extension: item.nameAndExtension.ext)
        announceSelection(in: pane, select: select, changed: changed)
    }

    func invertSelection() {
        activePane.model.invertSelection()
        announceSelection(in: activePane, select: true, changed: 1)
    }

    func restoreSelection() {
        let pane = activePane
        guard !pane.model.previousSelection.isEmpty else { return announce("No earlier selection") }
        pane.model.restoreSelection()
        announceSelection(in: pane, select: true, changed: 1)
    }

    /// Same words as Space: "Selected, 3 items", "Deselected, 1 item", "Deselected".
    private func announceSelection(in pane: PaneViewController, select: Bool, changed: Int) {
        let count = pane.model.selected.count
        if changed == 0 { return announce("No matching items") }
        if select { return announce("Selected, \(itemCount(count))") }
        announce(count > 0 ? "Deselected, \(itemCount(count))" : "Deselected")
    }

    private struct MaskAnswer {
        let mask: String
        let includeFolders: Bool
    }

    /// The Select Group / Deselect Group sheet: a mask with the masks used before, and whether
    /// folders count. Both sheets share the history, like TC.
    private func askMask(in window: NSWindow, select: Bool) async -> MaskAnswer? {
        let history = defaults.stringArray(forKey: Self.maskHistoryKey) ?? []
        let alert = NSAlert()
        alert.messageText = select ? "Select group:" : "Deselect group:"
        alert.informativeText = "Patterns such as *.mp3;*.flac, exclusions after |"
        alert.addButton(withTitle: select ? "Select" : "Deselect")
        alert.addButton(withTitle: "Cancel")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 30, width: 420, height: 26))
        combo.addItems(withObjectValues: history)
        combo.stringValue = history.first ?? "*"
        combo.completes = true
        combo.setAccessibilityLabel("Mask")
        let folders = NSButton(checkboxWithTitle: "Include folders", target: nil, action: nil)
        folders.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        folders.state = defaults.bool(forKey: Self.includeFoldersKey) ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        accessory.addSubview(combo)
        accessory.addSubview(folders)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = combo

        let confirmed: Bool = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            alert.window.makeFirstResponder(combo)
            combo.currentEditor()?.selectAll(nil)
        }
        let mask = combo.stringValue.trimmingCharacters(in: .whitespaces)
        guard confirmed, !mask.isEmpty else { return nil }
        let includeFolders = folders.state == .on
        defaults.set(includeFolders, forKey: Self.includeFoldersKey)
        defaults.set(Array(([mask] + history.filter { $0 != mask }).prefix(Self.maskHistoryLimit)),
                     forKey: Self.maskHistoryKey)
        return MaskAnswer(mask: mask, includeFolders: includeFolders)
    }
}
