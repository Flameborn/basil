import AppKit
import BasilCore
import BasilIntegrations
import BasilOperations
import BasilVFS

/// F4 on a file inside an archive or on a server: Basil extracts or downloads a temporary copy
/// and opens it in the editor. When Basil becomes active again and the copy has changed, it asks
/// once whether to put the copy back (Update / Upload, Not Now, Stop Watching). "Not Now" asks
/// again only after a further save. An upload first checks that the server's file is still the
/// one that was downloaded and asks before replacing someone else's change. Quitting with
/// changes that are not back yet asks first.
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
        // A search inside archives opens them as it goes.
        if findWindow?.isSearching == true { return }
        var keep = copies.locationsInUse
        for pane in [left, right] {
            keep.append(pane.model.directory.location)
            if let loading = pane.model.loadingTarget { keep.append(loading.location) }
            keep += pane.tabs.map(\.directory.location)
        }
        // Search results go once nothing shows them; the archive they were found in stays while they are shown.
        providers.closeListings(keeping: Set(keep))
        // Archives searched with "Search inside archives": open while results show their items.
        keep += keep.flatMap { providers.listing($0)?.locationsInUse ?? [] }
        keep += findWindow?.locationsInUse ?? []
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

    /// F4 on a server: downloads a copy and watches it. A server that can't be written to opens
    /// the copy unwatched with a spoken note.
    func editOnServer(_ path: VFSPath, app: String?) {
        let writable = (try? providers.writableProvider(for: path.location))?.capabilities.contains(.write) ?? false
        let editor = app ?? settings.settings.editorAppPath
        let server = serverName(of: path.location)
        Task {
            do {
                let copy = try await copies.extractForEditing(path, watch: writable)
                try await EditorLauncher.open(URL(fileURLWithPath: copy.path), editorAppPath: editor)
                if !writable {
                    announce("Opened a copy of \(path.name). \(server) is read-only. Changes stay in the copy.")
                }
            } catch is CancellationError {
            } catch {
                announce("Could not edit \(path.name): \(error.localizedDescription)")
            }
        }
    }

    /// "alice@example.com" for a connection, else the provider's name.
    func serverName(of location: ProviderLocation) -> String {
        (try? providers.provider(for: location) as? any ConnectedProvider)?.connectionTitle ?? location.instance
    }

    /// Where an edited copy goes back to: the archive's name or the server's.
    private func home(of edit: TemporaryCopies.EditedCopy) -> String {
        edit.entry.location.container?.name ?? serverName(of: edit.entry.location)
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
                let alert = NSAlert()
                alert.messageText = "\(edit.entry.name) was changed"
                alert.informativeText = edit.isRemote ? "Upload it to \(home(of: edit))?" : "Update it in \(home(of: edit))?"
                alert.addButton(withTitle: edit.isRemote ? "Upload" : "Update")
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
        if edit.isRemote { return upload(edit) }
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

    private func upload(_ edit: TemporaryCopies.EditedCopy) {
        guard let stamp = copies.currentStamp(of: edit.id) else { return }
        let s = settings.settings
        let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries,
                                        secure: s.secureCopy)
        let operation = UploadEditedCopyOperation(copy: edit.copy, destination: edit.entry, downloaded: edit.server,
                                                  server: serverName(of: edit.entry.location),
                                                  registry: providers, options: options)
        let queued = queue.add(operation)
        queued.whenDone = { [weak self] state in
            guard let self else { return }
            switch state {
            case .finished: copies.markPutBack(edit.id, at: stamp, server: operation.result.fingerprint)
            // The server's version was kept: ask again only after a further save.
            case .cancelled: copies.dismiss(edit.id)
            default: break
            }
        }
    }

    /// Called when Basil is about to quit. Returns false when the user stays to update an archive.
    public func confirmQuitWithEditedCopies() -> Bool {
        let unsaved = copies.unsavedEdits()
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        if unsaved.count == 1 {
            let edit = unsaved[0]
            alert.messageText = "Changes to \(edit.entry.name) are not \(edit.isRemote ? "on" : "in") \(home(of: edit)) yet"
        } else if unsaved.allSatisfy({ !$0.isRemote }) {
            alert.messageText = "Changes to \(unsaved.count) edited files are not in their archives yet"
        } else if unsaved.allSatisfy(\.isRemote) {
            alert.messageText = "Changes to \(unsaved.count) edited files are not on their servers yet"
        } else {
            alert.messageText = "Changes to \(unsaved.count) edited files are not in their archives or on their servers yet"
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
