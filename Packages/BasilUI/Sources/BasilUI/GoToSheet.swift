import AppKit
import BasilCore
import BasilVFS

/// Cmd+G: a sheet with a path field and a list of suggestions for the last part of the path.
/// "/vo" suggests Volumes, "~/Do" Documents and Downloads; relative paths start in the pane's folder.
/// Up and Down pick a suggestion, Tab completes it (folders get a trailing slash), Return goes there,
/// Escape cancels. Focus stays in the field; the picked suggestion and the number of suggestions are
/// announced for VoiceOver.
@MainActor
final class GoToSheetController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Suggestion: Sendable {
        let item: FileItem
        var isDirectory: Bool { item.isDirectoryLike }
        var spoken: String { isDirectory ? "\(item.name), dir" : item.name }
    }

    private let baseDirectory: VFSPath
    private let registry: ProviderRegistry
    private let resolve: (String) -> VFSPath?
    private let announce: (String) -> Void
    /// Goes to the path; returns false when it doesn't exist (the sheet then stays open).
    var onGo: ((VFSPath) async -> Bool)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let list = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var suggestions: [Suggestion] = []
    private var listings: [VFSPath: [FileItem]] = [:]
    private var generation = 0
    private var lastAnnouncedCount: Int?
    private var announceTask: Task<Void, Never>?
    private static let maxSuggestions = 200

    init(baseDirectory: VFSPath, registry: ProviderRegistry, resolve: @escaping (String) -> VFSPath?,
         announce: @escaping (String) -> Void) {
        self.baseDirectory = baseDirectory
        self.registry = registry
        self.resolve = resolve
        self.announce = announce
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Go to folder or file:")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        field.placeholderString = "Path, for example /Applications or ~/Downloads"
        field.setAccessibilityLabel("Path")
        field.setAccessibilityIdentifier("goto.field")
        field.delegate = self
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Suggestion"
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = Theme.rowHeight
        list.style = .plain
        list.allowsEmptySelection = true
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(listDoubleClicked)
        list.refusesFirstResponder = true
        list.setAccessibilityLabel("Suggestions")
        list.setAccessibilityIdentifier("goto.suggestions")
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        countLabel.textColor = Theme.secondaryText
        countLabel.setAccessibilityElement(false) // spoken through announcements instead

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let go = NSButton(title: "Go", target: self, action: #selector(goClicked))
        go.keyEquivalent = "\r"
        let buttons = NSStackView(views: [countLabel, NSView(), cancel, go])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, field, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            root.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.initialFirstResponder = field
        view.window?.makeFirstResponder(field)
    }

    // MARK: Suggestions

    /// The folder the last path part is looked up in, and that part ("/Ap" -> "/", "Ap").
    private func split(_ text: String) -> (folderText: String, folder: VFSPath, prefix: String)? {
        guard let slash = text.lastIndex(of: "/") else {
            return text == "~" ? nil : ("", baseDirectory, text)
        }
        let folderText = String(text[...slash])
        let prefix = String(text[text.index(after: slash)...])
        guard let folder = folderText == "/" ? VFSPath(location: baseDirectory.location, path: "/") : resolve(folderText)
        else { return nil }
        return (folderText, folder, prefix)
    }

    func controlTextDidChange(_ obj: Notification) { refreshSuggestions() }

    private func refreshSuggestions() {
        generation += 1
        let gen = generation
        let text = field.stringValue
        guard !text.isEmpty, let (_, folder, prefix) = split(text) else { return show([], gen) }
        Task {
            var items = listings[folder] ?? []
            if listings[folder] == nil {
                guard let provider = try? registry.provider(for: folder.location) else { return show([], gen) }
                var loaded: [FileItem] = []
                do {
                    for try await batch in provider.list(folder) { loaded += batch }
                } catch {
                    return show([], gen)
                }
                let unsorted = loaded
                let order = ListSortOrder.default
                items = await Task.detached { ItemSorter.sorted(unsorted, by: order) }.value
                listings[folder] = items
                guard gen == generation else { return }
            }
            let limit = Self.maxSuggestions
            let items2 = items
            let matches = await Task.detached { Self.match(items2, prefix: prefix, limit: limit) }.value
            show(matches, gen)
        }
    }

    /// Names starting with `prefix` first, then names containing it, case-insensitive. Hidden items
    /// (like /Volumes) appear once something is typed; dot files only when the prefix starts with a dot.
    nonisolated static func match(_ items: [FileItem], prefix: String, limit: Int) -> [Suggestion] {
        let needle = prefix.lowercased()
        var starts: [Suggestion] = [], contains: [Suggestion] = []
        for item in items {
            if needle.isEmpty {
                if item.isHidden { continue }
            } else if item.name.hasPrefix("."), !needle.hasPrefix(".") {
                continue
            }
            let name = item.name.lowercased()
            if name.hasPrefix(needle) {
                starts.append(Suggestion(item: item))
            } else if name.contains(needle) {
                contains.append(Suggestion(item: item))
            }
            if starts.count >= limit { break }
        }
        return Array((starts + contains).prefix(limit))
    }

    private func show(_ matches: [Suggestion], _ gen: Int) {
        guard gen == generation else { return }
        suggestions = matches
        list.reloadData()
        list.deselectAll(nil)
        let count = matches.count
        countLabel.stringValue = field.stringValue.isEmpty ? "" : suggestionCount(count)
        // Spoken once typing pauses, and only when the number changed, so it doesn't talk over typing.
        announceTask?.cancel()
        guard !field.stringValue.isEmpty else { return }
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.lastAnnouncedCount != count else { return }
            self.lastAnnouncedCount = count
            self.announce(self.suggestionCount(count))
        }
    }

    private func suggestionCount(_ n: Int) -> String {
        switch n {
        case 0: "No suggestions"
        case 1: "1 suggestion"
        default: "\(n) suggestions"
        }
    }

    // MARK: Keys in the field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): pick(by: 1)
        case #selector(NSResponder.moveUp(_:)): pick(by: -1)
        case #selector(NSResponder.insertTab(_:)): complete()
        case #selector(NSResponder.insertNewline(_:)): goClicked()
        case #selector(NSResponder.cancelOperation(_:)): cancelClicked()
        default: return false
        }
        return true
    }

    private func pick(by delta: Int) {
        guard !suggestions.isEmpty else { return NSSound.beep() }
        let current = list.selectedRow
        let row = current < 0 ? (delta > 0 ? 0 : suggestions.count - 1)
            : max(0, min(suggestions.count - 1, current + delta))
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        list.scrollRowToVisible(row)
        announce(suggestions[row].spoken)
    }

    /// Tab: fills in the picked (or first) suggestion; folders get a trailing slash.
    private func complete() {
        let row = list.selectedRow >= 0 ? list.selectedRow : 0
        guard suggestions.indices.contains(row), let (folderText, _, _) = split(field.stringValue) else {
            return NSSound.beep()
        }
        let suggestion = suggestions[row]
        field.stringValue = folderText + suggestion.item.name + (suggestion.isDirectory ? "/" : "")
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        announce(suggestion.spoken)
        refreshSuggestions()
    }

    // MARK: Actions

    @objc private func goClicked() {
        let target: VFSPath?
        if list.selectedRow >= 0, suggestions.indices.contains(list.selectedRow) {
            target = suggestions[list.selectedRow].item.path
        } else {
            target = resolve(field.stringValue)
        }
        guard let target else { return NSSound.beep() }
        Task {
            if await onGo?(target) == true {
                onClose?()
            } else {
                NSSound.beep()
                announce("\(target.name) not found")
            }
        }
    }

    @objc private func cancelClicked() { onClose?() }

    @objc private func listDoubleClicked() {
        guard list.clickedRow >= 0 else { return }
        list.selectRowIndexes(IndexSet(integer: list.clickedRow), byExtendingSelection: false)
        goClicked()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("suggestion")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            image.setAccessibilityElement(false)
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for v in [image, text] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let suggestion = suggestions[row]
        cell.textField?.stringValue = suggestion.item.name
        cell.textField?.setAccessibilityLabel(suggestion.spoken)
        cell.setAccessibilityLabel(suggestion.spoken)
        cell.imageView?.image = Icons.icon(for: suggestion.item)
        return cell
    }
}

extension MainWindowController {
    /// Cmd+G: go to a folder, or to a file's folder with the cursor on the file.
    func goToPath() {
        guard let window else { return }
        let pane = activePane
        let controller = GoToSheetController(
            baseDirectory: pane.model.directory, registry: providers,
            resolve: { [weak self, weak pane] text in
                guard let self, let pane else { return nil }
                return self.resolve(text, relativeTo: pane.model.directory)
            },
            announce: { [weak self] in self?.announce($0) })
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Go to Folder or File"
        controller.onClose = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        controller.onGo = { [weak self, weak pane] target in
            guard let self, let pane,
                  let item = try? await self.providers.provider(for: target.location).item(at: target) else { return false }
            if item.isDirectoryLike {
                pane.navigate(to: target)
            } else if let parent = target.parent {
                pane.navigate(to: parent, cursor: target)
            }
            return true
        }
        window.beginSheet(sheet) { [weak self] _ in
            guard let self else { return }
            window.makeFirstResponder(self.activePane.tableView)
        }
    }
}
