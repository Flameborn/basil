import AppKit
import BasilCore
import BasilIntegrations
import BasilOperations
import BasilVFS

/// F4 on a file inside an archive: Basil extracts a temporary copy and opens it in the editor.
/// When Basil becomes active again and the copy has changed, it asks once whether to put the
/// copy back into the archive (Update / Not Now / Stop Watching). "Not Now" asks again only after
/// a further save. Quitting with changes that are not in their archive asks first.
extension MainWindowController {
    /// Every archive (also the outer ones of nested archives) shown by a pane's folder.
    var shownContainers: Set<VFSPath> {
        var shown = Set<VFSPath>()
        for pane in [left, right] {
            var container = pane.model.directory.location.container
            while let c = container {
                shown.insert(c)
                container = c.location.container
            }
        }
        return shown
    }

    /// Closes the archives and file lists nothing uses any more, so their index, open files and
    /// temporary copies go. Kept: what the panes and their tabs show or are loading, and what the
    /// temporary copies need. Nothing is closed while the queue has items to run: an operation
    /// may read or change any container.
    func closeUnusedContainers() {
        guard queue.items.allSatisfy(\.state.isDone) else { return }
        var keep = copies.locationsInUse
        for pane in [left, right] {
            keep.append(pane.model.directory.location)
            if let loading = pane.model.loadingTarget { keep.append(loading.location) }
            keep += pane.tabs.map(\.directory.location)
        }
        providers.closeContainers(keeping: keep)
    }

    func editInArchive(_ entry: VFSPath, app: String?) {
        guard let archive = entry.location.container else { return }
        let refusal: String? = if let writer = providers.containerWriter(for: entry.location) {
            writer.updateRefusal(for: archive, registry: providers)
        } else {
            "\(archive.name) is read-only."
        }
        let editor = app ?? settings.settings.editorAppPath
        Task {
            do {
                let copy = try await copies.extractForEditing(entry, watch: refusal == nil)
                try await EditorLauncher.open(URL(fileURLWithPath: copy.path), editorAppPath: editor)
                if let refusal {
                    announce("Opened a copy of \(entry.name). \(refusal) Changes stay in the copy.")
                }
            } catch is CancellationError {
            } catch {
                announce("Could not edit \(entry.name): \(error.localizedDescription)")
            }
        }
    }

    /// Basil became active: asks about each watched copy that changed, one sheet at a time.
    func offerEditedCopies() {
        guard !offeringEditedCopies, let window, window.attachedSheet == nil else { return }
        let changed = copies.changedEdits()
        guard !changed.isEmpty else { return }
        offeringEditedCopies = true
        Task {
            defer { offeringEditedCopies = false }
            for edit in changed {
                guard let archive = edit.entry.location.container else { continue }
                let alert = NSAlert()
                alert.messageText = "\(edit.entry.name) was changed"
                alert.informativeText = "Update it in \(archive.name)?"
                alert.addButton(withTitle: "Update")
                alert.addButton(withTitle: "Not Now")
                alert.addButton(withTitle: "Stop Watching")
                switch await present(alert, in: window) {
                case 0: putBack(edit)
                case 1: copies.dismiss(edit.id)
                default: copies.stopWatching(edit.id)
                }
            }
        }
    }

    private func putBack(_ edit: TemporaryCopies.EditedCopy) {
        guard let archive = edit.entry.location.container, let stamp = copies.currentStamp(of: edit.id) else { return }
        let s = settings.settings
        let queued = queue.add(ArchiveUpdateOperation(.update(source: edit.copy, entry: edit.entry),
                                                      macMetadata: s.packMacMetadata,
                                                      unstableRetries: s.unstableSourceRetries, registry: providers))
        queued.whenDone = { [weak self] state in
            guard let self else { return }
            reloadPanes(showingArchive: archive)
            if state == .finished { copies.markPutBack(edit.id, at: stamp) }
        }
    }

    /// Called when Basil is about to quit. Returns false when the user stays to update an archive.
    public func confirmQuitWithEditedCopies() -> Bool {
        let unsaved = copies.unsavedEdits()
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        if unsaved.count == 1, let archive = unsaved[0].entry.location.container {
            alert.messageText = "Changes to \(unsaved[0].entry.name) are not in \(archive.name) yet"
        } else {
            alert.messageText = "Changes to \(unsaved.count) edited files are not in their archives yet"
        }
        alert.informativeText = "If you quit now, the changes are lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else {
            copies.clearDismissed()
            offerEditedCopies()
            return false
        }
        return true
    }

    /// Removes the F3 / F4 copies (at quit).
    public func removeTemporaryCopies() {
        copies.removeAll()
    }
}
