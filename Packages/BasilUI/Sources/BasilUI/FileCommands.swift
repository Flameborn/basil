import AppKit
import BasilCore
import BasilIntegrations
import BasilOperations
import BasilVFS

/// F5 copy, F6 move, Shift+F6 rename, F7 new folder, F8 delete: the dialogs that ask for a
/// target or a name, and the prompts operations show while they run. All file work is queued.
extension MainWindowController {
    // MARK: Commands

    func copyOrMove(_ mode: TransferMode) {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        guard let window, ensureReadable(activePane.model.directory) else { return }
        let sourceFolder = activePane.model.directory
        if mode == .move, !ensureWritable(sourceFolder, items: true) { return }
        let verb = mode == .copy ? "Copy" : "Move"
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        let other = otherPane.model.directory
        let initial = other.location == .local ? other.path : other.description
        Task {
            guard let text = await askText(in: window, message: "\(verb) \(what) to:", initial: initial,
                                           confirm: verb, fieldLabel: "Target folder") else { return }
            let target = text == initial ? other : resolve(text, relativeTo: activePane.model.directory)
            guard let target else { return }
            guard ensureWritable(target) else { return }
            let s = settings.settings
            let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries,
                                            secure: s.secureCopy)
            let sources = items.map(\.path)
            if let archive = target.location.container {
                // Into an archive: the target must be one of its folders.
                let kind = try? await providers.provider(for: target.location).item(at: target).kind
                guard kind == .directory else { return activePane.report("Choose a folder inside \(archive.name) as the target.") }
                let action = ArchiveUpdateOperation.Action.add(sources: sources, into: target, move: mode == .move)
                queueArchiveUpdate(action, reloading: [archive])
            } else if mode == .move, let archive = sourceFolder.location.container {
                queueArchiveUpdate(.moveOut(sources: sources, target: target, options: options), reloading: [archive])
            } else {
                queue.add(TransferOperation(mode: mode, sources: sources, target: target,
                                            registry: providers, options: options))
            }
            activePane.model.deselectAll()
        }
    }

    /// Shift+F5: copies the selected items (or the cursor item) into the same folder as
    /// "name (2).ext", the first free number. One item goes at once; several are confirmed first.
    func duplicateItems() {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        let directory = activePane.model.directory
        guard let window, ensureReadable(directory), ensureWritable(directory, archives: false, items: true) else { return }
        let pane = activePane
        Task {
            if items.count > 1 {
                guard await confirm(in: window, message: "Duplicate \(FeedbackText.items(items.count))?",
                                    confirm: "Duplicate") else { return }
            }
            let s = settings.settings
            let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries,
                                            secure: s.secureCopy)
            let queued = queue.add(TransferOperation(duplicating: items.map(\.path), registry: providers, options: options))
            pane.model.deselectAll()
            queued.whenDone = { _ in
                if pane.model.directory == directory { pane.model.reload(cursor: pane.cursorItem?.path) }
            }
        }
    }

    func renameCursorItem() {
        guard let item = activePane.cursorItem, let parent = item.path.parent else { return announce("No items") }
        guard let window, ensureWritable(parent) else { return }
        let pane = activePane
        let baseLength = item.isDirectoryLike ? item.name.utf16.count
            : (item.name as NSString).deletingPathExtension.utf16.count
        Task {
            guard let name = await askText(in: window, message: "Rename \(item.name) to:", initial: item.name,
                                           selection: NSRange(location: 0, length: baseLength),
                                           confirm: "Rename", fieldLabel: "New name"),
                  !name.isEmpty, name != item.name else { return }
            guard !name.contains("/") else {
                announce("A name cannot contain a slash")
                return
            }
            let destination = parent.appending(name)
            if let archive = parent.location.container {
                queueArchiveUpdate(.rename(from: item.path, to: destination), reloading: [archive], cursor: destination, in: pane)
                return
            }
            let queued = queue.add(RenameOperation(source: item.path, destination: destination, registry: providers))
            queued.whenDone = { [weak self] state in
                guard state == .finished else { return }
                self?.itemsRenamed([(item.path, destination)], in: pane, cursor: destination)
            }
        }
    }

    /// Cmd+M: the Multi-Rename tool for the selected items, or the cursor item. In search results
    /// the items come from several folders: each folder is listed first, so names clash only with
    /// names in the item's own folder, and the results show the new names afterwards.
    func multiRename() {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        let pane = activePane
        let directory = pane.model.directory
        let listing = Listings.info(directory.location)
        if let listing, listing.origin.location.container != nil || items.contains(where: { $0.path.location.container != nil }) {
            return pane.report("Items found inside an archive can only be copied out of it.")
        }
        guard ensureWritable(listing?.origin ?? directory, archives: false) else { return }
        guard listing != nil else {
            return openMultiRename(items, existing: [directory: Set(pane.model.allItems.map(\.name))], in: pane)
        }
        let folders = Set(items.compactMap(\.path.parent))
        let registry = providers
        Task {
            var existing: [VFSPath: Set<String>] = [:]
            for folder in folders {
                guard let provider = try? registry.provider(for: folder.location) else { continue }
                var names: Set<String> = []
                do {
                    for try await batch in provider.list(folder) { names.formUnion(batch.map(\.name)) }
                } catch {
                    return pane.report("Could not read \(folder.displayName): \(PaneViewController.describe(error))")
                }
                existing[folder] = names
            }
            // The tool runs a modal loop. Started from this task (or a main-queue block) the main
            // queue would stay busy with it and the preview's own tasks would never run, so it
            // starts from the run loop, like after a key press.
            let found = existing
            RunLoop.main.perform {
                MainActor.assumeIsolated { self.openMultiRename(items, existing: found, in: pane) }
            }
        }
    }

    private func openMultiRename(_ items: [FileItem], existing: [VFSPath: Set<String>], in pane: PaneViewController) {
        let log = dataDirectory.appendingPathComponent("LastMultiRename.json")
        let model = MultiRenameModel(items: items, existingNames: existing, undoLog: log)
        let controller = MultiRenameWindowController(model: model, settings: settings)
        model.onStart = { [weak self, weak controller] entries in
            guard let self else { return }
            controller?.close()
            let pairs = entries.filter { !$0.isUnchanged }.compactMap { entry in
                entry.item.path.parent.map { MultiRenameOperation.Pair(source: entry.item.path, destination: $0.appending(entry.newName)) }
            }
            let cursor = pane.cursorItem?.path
            let newCursor = pairs.first { $0.source == cursor }?.destination ?? cursor
            let queued = queue.add(MultiRenameOperation(pairs: pairs, undoLog: log, registry: providers))
            pane.model.deselectAll()
            queued.whenDone = { [weak self] _ in
                self?.itemsRenamed(pairs.map { ($0.source, $0.destination) }, in: pane, cursor: newCursor)
            }
        }
        model.onUndo = { [weak self, weak controller] in
            guard let self else { return }
            controller?.close()
            guard let undo = MultiRenameOperation.undo(log: log, registry: providers) else { return announce("Nothing to undo") }
            let cursor = pane.cursorItem?.path
            let newCursor = undo.pairs.first { $0.source == cursor }?.destination ?? cursor
            let queued = queue.add(undo)
            queued.whenDone = { [weak self] _ in
                self?.itemsRenamed(undo.pairs.map { ($0.source, $0.destination) }, in: pane, cursor: newCursor)
            }
        }
        controller.runModal()
    }

    /// Rereads the pane after renames. Search results first take the new names of the items that
    /// were renamed (a rename that failed or was skipped keeps its old name), so they stay listed.
    func itemsRenamed(_ pairs: [(VFSPath, VFSPath)], in pane: PaneViewController, cursor: VFSPath?) {
        guard !pairs.isEmpty, let listing = providers.listing(pane.model.directory.location) else {
            return pane.model.reload(cursor: cursor)
        }
        let registry = providers
        Task {
            var done: [(from: VFSPath, to: VFSPath)] = []
            for (from, to) in pairs {
                guard let provider = try? registry.provider(for: to.location) else { continue }
                // Moved when the new path exists and the old one does not (a case-only change has both).
                let arrived = (try? await provider.item(at: to)) != nil
                var left = from.path.lowercased() == to.path.lowercased()
                if !left { left = (try? await provider.item(at: from)) == nil }
                if arrived, left { done.append((from, to)) }
            }
            listing.itemsMoved(done)
            pane.model.reload(cursor: cursor)
        }
    }

    func makeDirectory() {
        guard let window, ensureWritable(activePane.model.directory) else { return }
        let pane = activePane
        let directory = pane.model.directory
        Task {
            guard let name = await askText(in: window, message: "New folder:", initial: "",
                                           confirm: "Create", fieldLabel: "Folder name"),
                  !name.isEmpty else { return }
            guard let path = resolve(name, relativeTo: directory) else { return }
            if let archive = path.location.container {
                queueArchiveUpdate(.makeDirectory(path), reloading: [archive], cursor: path, in: pane)
                return
            }
            let queued = queue.add(MakeDirectoryOperation(path: path, registry: providers))
            queued.whenDone = { state in
                if state == .finished, pane.model.directory == path.parent { pane.model.reload(cursor: path) }
            }
        }
    }

    /// Shift+F4 (Total Commander): asks for a name (prefilled with the cursor file's name), creates
    /// an empty file through the queue unless it exists, then opens it in the editor from Settings.
    func newFile() {
        guard let window, ensureWritable(activePane.model.directory, archives: false) else { return }
        let pane = activePane
        let directory = pane.model.directory
        let initial = pane.cursorItem.flatMap { $0.isDirectoryLike ? nil : $0.name } ?? ""
        Task {
            guard let name = await askText(in: window, message: "New file:", initial: initial,
                                           confirm: "Create", fieldLabel: "File name"),
                  let path = resolve(name, relativeTo: directory) else { return }
            if let existing = try? await providers.provider(for: path.location).item(at: path) {
                if existing.isDirectoryLike { return announce("\(path.name) is a folder") }
                return openInEditor(path)
            }
            let queued = queue.add(NewFileOperation(path: path, registry: providers))
            queued.whenDone = { state in
                guard state == .finished else { return }
                if pane.model.directory == path.parent { pane.model.reload(cursor: path) }
                self.openInEditor(path)
            }
        }
    }

    /// F4 (Total Commander): edits the cursor file. The first editor rule in Settings whose
    /// patterns match the name decides: one app opens directly, several show a menu at the cursor
    /// row. Without a matching rule the global editor is used.
    func editCursorItem() {
        guard let item = activePane.cursorItem else { return announce("No items") }
        if item.isDirectoryLike { return announce("\(item.name) is a folder") }
        guard ensureReadable(activePane.model.directory) else { return }
        guard let apps = EditorRules.apps(for: item.name, in: settings.settings.editorRules) else {
            return edit(item.path, app: nil)
        }
        if apps.count == 1 { return edit(item.path, app: apps[0]) }
        let menu = NSMenu(title: "Edit \(item.name) with")
        menu.autoenablesItems = false
        for app in apps {
            menu.addItem(ClosureMenuItem(title: EditorLauncher.displayName(ofApp: app)) { [weak self] in
                self?.edit(item.path, app: app)
            })
        }
        activePane.popUpMenuAtCursor(menu)
    }

    /// Opens a local file (or one on a mounted share, in place) in the editor, or a temporary
    /// copy of a file inside an archive or on a server (ArchiveEditing.swift).
    func edit(_ path: VFSPath, app: String?) {
        if let local = providers.localPath(of: path) { return openInEditor(local, app: app) }
        if path.location.container != nil { return editInArchive(path, app: app) }
        editOnServer(path, app: app)
    }

    /// Cmd+Shift+T: opens the terminal from Settings in the current pane's folder.
    func openTerminal() {
        guard let directory = providers.localPath(of: activePane.model.directory) else {
            return announce("Only local folders and folders on mounted shares can be opened in a terminal")
        }
        let s = settings.settings
        Task {
            do {
                try await TerminalLauncher.open(URL(fileURLWithPath: directory.path, isDirectory: true),
                                                terminalID: s.terminalID, command: s.terminalCommand)
            } catch {
                announce("Could not open the terminal: \(error.localizedDescription)")
            }
        }
    }

    /// Opens a local file in `app` (a path to an .app bundle), or the editor chosen in Settings
    /// (or the system default app) when `app` is nil.
    func openInEditor(_ path: VFSPath, app: String? = nil) {
        guard path.location == .local else { return announce("Only local files can be edited for now") }
        let editor = app ?? settings.settings.editorAppPath
        Task {
            do {
                try await EditorLauncher.open(URL(fileURLWithPath: path.path), editorAppPath: editor)
            } catch {
                announce("Could not open the editor: \(error.localizedDescription)")
            }
        }
    }

    func delete(permanently: Bool) {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        guard let window, ensureWritable(activePane.model.directory, items: true) else { return }
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        // In search results the items' own place decides (the folder searched).
        let place = Listings.info(activePane.model.directory.location)?.origin.location ?? activePane.model.directory.location
        let canTrash = (try? providers.writableProvider(for: place))?.capabilities.contains(.trash) ?? false
        let toTrash = !permanently && canTrash
        let archive = activePane.model.directory.location.container
        let alert = NSAlert()
        alert.messageText = toTrash ? "Move \(what) to the Trash?"
            : archive.map { "Delete \(what) from \($0.name)?" } ?? "Delete \(what) permanently?"
        if !toTrash { alert.informativeText = "This cannot be undone." }
        alert.alertStyle = toTrash ? .informational : .warning
        alert.addButton(withTitle: toTrash ? "Move to Trash" : "Delete")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await present(alert, in: window) == 0 else { return }
            if let archive {
                queueArchiveUpdate(.delete(items.map(\.path)), reloading: [archive])
            } else {
                let apps = appIdentities(in: items)
                let queued = queue.add(DeleteOperation(paths: items.map(\.path), toTrash: toTrash, registry: providers))
                if !apps.isEmpty {
                    queued.whenDone = { [weak self] _ in self?.offerLeftovers(of: apps, toTrash: toTrash) }
                }
            }
            activePane.model.deselectAll()
        }
    }

    /// Option+Shift+F9 (Total Commander's Alt+Shift+F9): tests the selected archives, or the
    /// cursor archive, in the queue.
    func testArchives() {
        let archives = targetItems.filter { item in
            guard case .file = item.kind else { return false }
            return providers.containerOpener(forFile: item.path) != nil
        }
        guard !archives.isEmpty else { return announce("No archives") }
        queue.add(TestArchiveOperation(archives: archives.map(\.path), registry: providers))
        activePane.model.deselectAll()
    }

    /// False, with a spoken and shown reason, when the files in `directory` have no contents to
    /// read: a file list (.lst) only has their names, sizes and dates.
    func ensureReadable(_ directory: VFSPath) -> Bool {
        let capabilities = (try? providers.provider(for: directory.location))?.capabilities ?? []
        if capabilities.contains(.read) || capabilities.contains(.write) { return true }
        let name = directory.location.container?.name ?? "This folder"
        activePane.report("\(name) is a file list: it has the names, sizes and dates of the files, not the files.")
        return false
    }

    /// False, with a spoken and shown reason, when items in `directory` can't be changed.
    /// Inside an archive that a container writer can change, true unless `archives` is false
    /// (commands that do not work inside archives yet). In search results nothing can be created;
    /// with `items` (commands that change the found items: move, delete, duplicate) the folder
    /// searched decides.
    func ensureWritable(_ directory: VFSPath, archives: Bool = true, items: Bool = false) -> Bool {
        if let listing = Listings.info(directory.location) {
            guard items else {
                activePane.report("Search results only list items found elsewhere. Choose a folder instead.")
                return false
            }
            guard listing.origin.location.container == nil,
                  !targetItems.contains(where: { $0.path.location.container != nil }) else {
                activePane.report("Items found inside an archive can only be copied out of it.")
                return false
            }
            return ensureWritable(listing.origin, archives: archives)
        }
        let capabilities = (try? providers.provider(for: directory.location))?.capabilities ?? []
        if capabilities.contains(.write) { return true }
        guard let archive = directory.location.container else {
            activePane.report("This folder is read-only.")
            return false
        }
        guard archives else {
            activePane.report("This does not work inside archives yet.")
            return false
        }
        guard let writer = providers.containerWriter(for: directory.location) else {
            activePane.report("\(archive.name) is read-only.")
            return false
        }
        if let refusal = writer.updateRefusal(for: archive, registry: providers) {
            activePane.report(refusal)
            return false
        }
        return true
    }

    /// Queues a change inside an archive and rereads the panes showing it when it is done.
    func queueArchiveUpdate(_ action: ArchiveUpdateOperation.Action, reloading archives: [VFSPath],
                            cursor: VFSPath? = nil, in pane: PaneViewController? = nil) {
        let s = settings.settings
        let queued = queue.add(ArchiveUpdateOperation(action, macMetadata: s.packMacMetadata,
                                                      unstableRetries: s.unstableSourceRetries, registry: providers))
        queued.whenDone = { [weak self] state in
            for archive in archives { self?.reloadPanes(showingArchive: archive) }
            if state == .finished, let cursor, let pane { pane.model.reload(cursor: cursor) }
        }
    }

    /// A typed path: absolute, "~/..." or relative to `directory`. Inside an archive, an absolute
    /// path means a local folder.
    func resolve(_ text: String, relativeTo directory: VFSPath) -> VFSPath? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return VFSPath(location: directory.location.container == nil ? directory.location : .local, path: expanded)
        }
        var path = directory
        for part in expanded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": path = path.parent ?? path
            default: path = path.appending(String(part))
            }
        }
        return path
    }

    // MARK: Prompts from running operations

    func answer(_ prompt: QueuePrompt) async -> QueuePromptAnswer {
        guard let window else {
            switch prompt {
            case .conflict: return .conflict(.skip)
            case .unstableSource: return .unstableSource(.skip)
            case .itemFailed: return .itemFailed(.fail)
            case .folderExists: return .folderExists(.skip, forAll: false)
            case .changedOnServer: return .changedOnServer(replace: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        switch prompt {
        case .conflict(let c):
            let alert = NSAlert()
            alert.messageText = "\(c.destination.name) already exists"
            alert.informativeText = "New: \(describe(c.sourceFingerprint))\nExisting: \(describe(c.destinationFingerprint))\nIn \(c.destination.parent?.path ?? "")"
            let choices: [(String, ConflictChoice)] = [
                ("Overwrite", .overwrite), ("Skip", .skip), ("Overwrite All Older", .overwriteAllOlder),
                ("Overwrite All", .overwriteAll), ("Skip All", .skipAll), ("Rename", .rename), ("Cancel", .cancel),
            ]
            for (title, _) in choices { alert.addButton(withTitle: title) }
            let index = await present(alert, in: window)
            return .conflict(choices.indices.contains(index) ? choices[index].1 : .cancel)
        case .unstableSource(let u):
            let alert = NSAlert()
            alert.messageText = "\(u.path.name) keeps changing"
            alert.informativeText = "It changed while it was copied, \(u.attempts == 1 ? "1 time" : "\(u.attempts) times"). It may still be being written."
            let choices: [(String, UnstableSourceDecision)] = [
                ("Keep Retrying", .keepRetrying), ("Accept Latest Copy", .acceptLatest), ("Skip", .skip), ("Cancel", .cancel),
            ]
            for (title, _) in choices { alert.addButton(withTitle: title) }
            let index = await present(alert, in: window)
            return .unstableSource(choices.indices.contains(index) ? choices[index].1 : .cancel)
        case .itemFailed(let f):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = f.question
            // Most reasons already name the full path; only add the folder when they don't.
            let folder = f.path.parent?.path ?? ""
            alert.informativeText = f.reason.contains(folder) ? f.reason : "\(f.reason)\nIn \(folder)"
            let choices: [(String, ItemFailureChoice)] = [
                ("Retry", .retry), ("Skip", .skip), ("Skip All", .skipAll), ("Cancel", .cancel),
            ]
            for (title, _) in choices { alert.addButton(withTitle: title) }
            let index = await present(alert, in: window)
            return .itemFailed(choices.indices.contains(index) ? choices[index].1 : .cancel)
        case .folderExists(let f):
            let alert = NSAlert()
            alert.messageText = "\(f.folder.name) already exists"
            alert.informativeText = "Unpacking \(f.archive.name) would put its items into this folder.\nIn \(f.folder.parent?.path ?? "")"
            let choices: [(String, FolderExistsChoice)] = [
                ("Unpack into It", .merge), ("Use \(f.newName)", .newName), ("Skip", .skip), ("Cancel", .cancel),
            ]
            for (title, _) in choices { alert.addButton(withTitle: title) }
            if f.moreArchives {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Do the same for the other archives"
            }
            let index = await present(alert, in: window)
            let forAll = alert.suppressionButton?.state == .on
            return .folderExists(choices.indices.contains(index) ? choices[index].1 : .cancel, forAll: forAll)
        case .changedOnServer(let c):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(c.path.name) was changed on \(c.server) since you opened it"
            alert.informativeText = "Replace it with your copy?\nWhen you opened it: \(describe(c.then))\nNow: \(describe(c.now))\nIn \(c.path.parent?.path ?? "")"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            return .changedOnServer(replace: await present(alert, in: window) == 0)
        }
    }

    private func describe(_ fp: FileFingerprint) -> String {
        let date = fp.modifiedNanos.map { Date(timeIntervalSince1970: Double($0) / 1e9) }
        return "\(settings.settings.size.string(fp.size)), \(settings.formatters.date(date))"
    }

    // MARK: Events

    func handle(_ event: QueueEvent) {
        let feedback = settings.settings.feedback.feedback(for: event.kind, event.outcome)
        let values = FeedbackValues(kind: OperationKindCatalog.info(event.kind), title: event.title,
                                    done: event.done, total: event.total, reason: event.reason)
        feedbackPlayer.perform(feedback, values: values)
    }

    // MARK: Alert helpers

    /// Shows an alert as a sheet and returns the index of the button pressed. The first button
    /// has keyboard focus (as in Total Commander), so Space and VoiceOver start on it.
    func present(_ alert: NSAlert, in window: NSWindow) async -> Int {
        let first = alert.buttons.first
        alert.window.initialFirstResponder = first
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            }
            if let first { alert.window.makeFirstResponder(first) }
        }
    }

    /// A sheet with one text field. Returns nil when cancelled.
    func askText(in window: NSWindow, message: String, initial: String, selection: NSRange? = nil,
                         confirm: String, fieldLabel: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        field.setAccessibilityLabel(fieldLabel)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
            alert.window.makeFirstResponder(field)
            if let selection, let editor = field.currentEditor() {
                editor.selectedRange = selection
            }
        }
    }
}
