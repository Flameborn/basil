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
        guard let window else { return }
        let verb = mode == .copy ? "Copy" : "Move"
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        let initial = otherPane.model.directory.path
        Task {
            guard let text = await askText(in: window, message: "\(verb) \(what) to:", initial: initial,
                                           confirm: verb, fieldLabel: "Target folder") else { return }
            guard let target = resolve(text, relativeTo: activePane.model.directory) else { return }
            let s = settings.settings
            let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries,
                                            secure: s.secureCopy)
            queue.add(TransferOperation(mode: mode, sources: items.map(\.path), target: target,
                                        registry: providers, options: options))
            activePane.model.deselectAll()
        }
    }

    func renameCursorItem() {
        guard let item = activePane.cursorItem, let parent = item.path.parent else { return announce("No items") }
        guard let window else { return }
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
            let queued = queue.add(RenameOperation(source: item.path, destination: destination, registry: providers))
            queued.whenDone = { state in
                if state == .finished { pane.model.reload(cursor: destination) }
            }
        }
    }

    /// Cmd+M: the Multi-Rename tool for the selected items, or the cursor item.
    func multiRename() {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        let pane = activePane
        let log = dataDirectory.appendingPathComponent("LastMultiRename.json")
        let model = MultiRenameModel(items: items, existingNames: pane.model.allItems.map(\.name), undoLog: log)
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
            queued.whenDone = { _ in pane.model.reload(cursor: newCursor) }
        }
        model.onUndo = { [weak self, weak controller] in
            guard let self else { return }
            controller?.close()
            guard let undo = MultiRenameOperation.undo(log: log, registry: providers) else { return announce("Nothing to undo") }
            let cursor = pane.cursorItem?.path
            let newCursor = undo.pairs.first { $0.source == cursor }?.destination ?? cursor
            let queued = queue.add(undo)
            queued.whenDone = { _ in pane.model.reload(cursor: newCursor) }
        }
        controller.runModal()
    }

    func makeDirectory() {
        guard let window else { return }
        let pane = activePane
        let directory = pane.model.directory
        Task {
            guard let name = await askText(in: window, message: "New folder:", initial: "",
                                           confirm: "Create", fieldLabel: "Folder name"),
                  !name.isEmpty else { return }
            guard let path = resolve(name, relativeTo: directory) else { return }
            let queued = queue.add(MakeDirectoryOperation(path: path, registry: providers))
            queued.whenDone = { state in
                if state == .finished, pane.model.directory == path.parent { pane.model.reload(cursor: path) }
            }
        }
    }

    func delete(permanently: Bool) {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        guard let window else { return }
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        let canTrash = (try? providers.writableProvider(for: activePane.model.directory.location))?
            .capabilities.contains(.trash) ?? false
        let toTrash = !permanently && canTrash
        let alert = NSAlert()
        alert.messageText = toTrash ? "Move \(what) to the Trash?" : "Delete \(what) permanently?"
        if !toTrash { alert.informativeText = "This cannot be undone." }
        alert.alertStyle = toTrash ? .informational : .warning
        alert.addButton(withTitle: toTrash ? "Move to Trash" : "Delete")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await present(alert, in: window) == 0 else { return }
            queue.add(DeleteOperation(paths: items.map(\.path), toTrash: toTrash, registry: providers))
            activePane.model.deselectAll()
        }
    }

    /// A typed path: absolute, "~/..." or relative to `directory`.
    private func resolve(_ text: String, relativeTo directory: VFSPath) -> VFSPath? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return VFSPath(location: directory.location, path: expanded)
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
    private func present(_ alert: NSAlert, in window: NSWindow) async -> Int {
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
    private func askText(in window: NSWindow, message: String, initial: String, selection: NSRange? = nil,
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
