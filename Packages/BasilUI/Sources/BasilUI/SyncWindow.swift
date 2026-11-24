import AppKit
import BasilCore
import BasilOperations
import BasilSync
import BasilVFS

/// Commands > Synchronize Directories (Total Commander's Synchronize dirs): compares two
/// folders, lists every file with what synchronizing would do, lets the user change it per file,
/// and runs the result as one queue item. Each row is one sentence for VoiceOver
/// ("Music/song.mp3, left newer, copy to the right, left 1.5 MB 24.11.2026, right 1.4 MB 23.11.2026").
@MainActor
final class SyncWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: MainWindowController?
    private let defaults: UserDefaults
    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let filterField = NSTextField()
    private let toleranceField = NSTextField()
    private let subfolders = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let byContent = NSButton(checkboxWithTitle: "Compare content", target: nil, action: nil)
    private let ignoreHour = NSButton(checkboxWithTitle: "Ignore 1-hour differences", target: nil, action: nil)
    private let asymmetric = NSButton(checkboxWithTitle: "Asymmetric (make the right like the left)", target: nil, action: nil)
    private let showRight = NSButton(checkboxWithTitle: "Copy to the right", target: nil, action: nil)
    private let showLeft = NSButton(checkboxWithTitle: "Copy to the left", target: nil, action: nil)
    private let showEqual = NSButton(checkboxWithTitle: "Equal", target: nil, action: nil)
    private let showDifferent = NSButton(checkboxWithTitle: "Different", target: nil, action: nil)
    private let showSingles = NSButton(checkboxWithTitle: "On one side only", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let table = CompareTableView()
    private var compareButton: NSButton!
    private var stopButton: NSButton!
    private var syncButton: NSButton!

    private var leftFolder: VFSPath
    private var rightFolder: VFSPath
    private var suggested: (left: String, right: String)
    private var entries: [SyncEntry] = []
    /// Indices into `entries` of the rows shown.
    private var rows: [Int] = []
    /// Entries chosen with Space (by id).
    private var marked: Set<Int> = []
    /// Entries removed from this sync with minus or Delete (by id).
    private var removed: Set<Int> = []
    private var task: Task<Void, Never>?
    private var compared: (left: VFSPath, right: VFSPath)?
    var isComparing: Bool { task != nil }

    private enum Key {
        static let options = "sync.options"
        static let show = "sync.show"
    }

    init(controller: MainWindowController, defaults: UserDefaults, left: VFSPath, right: VFSPath) {
        self.controller = controller
        self.defaults = defaults
        leftFolder = left
        rightFolder = right
        suggested = (Self.text(for: left), Self.text(for: right))
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Synchronize Directories"
        window.basilAutosave("BasilSyncWindow")
        window.contentMinSize = NSSize(width: 860, height: 560)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        window.onCharacter = { [weak self] text in self?.handle(character: text) ?? false }
        build()
        restoreOptions()
        if !window.setFrameUsingName("BasilSyncWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func text(for folder: VFSPath) -> String {
        folder.location == .local ? folder.path : folder.description
    }

    /// Shows the window with the two panes' folders (unless it is comparing) and the focus in the left field.
    func show(left: VFSPath, right: VFSPath) {
        if !isComparing {
            leftFolder = left
            rightFolder = right
            suggested = (Self.text(for: left), Self.text(for: right))
            leftField.stringValue = suggested.left
            rightField.stringValue = suggested.right
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(leftField)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 12
            return stack
        }
        for (field, name, id) in [(leftField, "Left folder", "sync.left"), (rightField, "Right folder", "sync.right"),
                                  (filterField, "Files", "sync.filter"), (toleranceField, "Date tolerance in seconds", "sync.tolerance")] {
            field.setAccessibilityLabel(name)
            field.setAccessibilityIdentifier(id)
            field.target = self
            field.action = #selector(compare)
        }
        filterField.placeholderString = "*.jpg;*.png | tmp*, empty compares all files"
        toleranceField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        leftField.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        for box in [subfolders, byContent, ignoreHour, asymmetric] {
            box.target = self
            box.action = #selector(optionChanged)
        }
        for box in [showRight, showLeft, showEqual, showDifferent, showSingles] {
            box.target = self
            box.action = #selector(showChanged)
        }
        let showLabel = NSTextField(labelWithString: "Show:")
        let grid = NSGridView(views: [
            [label("Left folder:"), leftField],
            [label("Right folder:"), rightField],
            [label("Files:"), row(filterField, label("Date tolerance (seconds):"), toleranceField)],
            [NSGridCell.emptyContentView, row(subfolders, byContent, ignoreHour, asymmetric)],
            [showLabel, row(showRight, showLeft, showEqual, showDifferent, showSingles)],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        status.setAccessibilityLabel("Status")
        status.setAccessibilityIdentifier("sync.status")
        status.stringValue = "Press Return or Compare to compare the folders."
        status.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Files"))
        column.title = "Files"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // There is always a cursor row (clicking below the rows keeps it).
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = Theme.rowHeight + 2
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.setAccessibilityLabel("Files")
        table.setAccessibilityIdentifier("sync.results")
        table.dataSource = self
        table.delegate = self
        table.menu = contextMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        compareButton = NSButton(title: "Compare", target: self, action: #selector(compare))
        compareButton.setAccessibilityHelp("Return in the fields")
        stopButton = NSButton(title: "Stop Comparing", target: self, action: #selector(stop))
        stopButton.setAccessibilityHelp("Escape while comparing")
        syncButton = NSButton(title: "Synchronize Now", target: self, action: #selector(synchronize))
        syncButton.setAccessibilityHelp("Copies and deletes as the list says, in the queue. In the list: Comma copies to the left, Period to the right, Equals leaves a file alone, Minus or Delete removes it from this sync, Space selects")
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.setAccessibilityHelp("Escape")
        let buttons = NSStackView(views: [compareButton, stopButton, NSView(), syncButton, close])
        buttons.orientation = .horizontal
        updateButtons()

        let stack = NSStackView(views: [grid, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Copy to the Right", SyncAction.copyRight), ("Copy to the Left", .copyLeft),
                                ("Leave Alone", .none), ("Delete on the Right", .deleteRight)] {
            let item = NSMenuItem(title: title, action: #selector(menuSetAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action == .copyRight ? "right" : action == .copyLeft ? "left" : action == .none ? "none" : "delete"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from This Sync", action: #selector(removeChosen), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    private func updateButtons() {
        compareButton.isEnabled = !isComparing
        stopButton.isEnabled = isComparing
        syncButton.isEnabled = !isComparing && entries.contains { !removed.contains($0.id) && $0.action != .none }
    }

    // MARK: Options

    private func restoreOptions() {
        let options = defaults.data(forKey: Key.options).flatMap { try? JSONDecoder().decode(SyncOptions.self, from: $0) } ?? SyncOptions()
        subfolders.state = options.subfolders ? .on : .off
        byContent.state = options.byContent ? .on : .off
        ignoreHour.state = options.ignoreHour ? .on : .off
        asymmetric.state = options.asymmetric ? .on : .off
        filterField.stringValue = options.filter
        toleranceField.stringValue = String(options.toleranceSeconds)
        let show = defaults.array(forKey: Key.show) as? [Bool] ?? [true, true, true, true, true]
        for (box, on) in zip([showRight, showLeft, showEqual, showDifferent, showSingles], show + Array(repeating: true, count: 5)) {
            box.state = on ? .on : .off
        }
    }

    private var options: SyncOptions {
        var options = SyncOptions()
        options.subfolders = subfolders.state == .on
        options.byContent = byContent.state == .on
        options.ignoreHour = ignoreHour.state == .on
        options.asymmetric = asymmetric.state == .on
        options.filter = filterField.stringValue
        options.toleranceSeconds = max(0, Int(toleranceField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0)
        return options
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Key.options) }
        defaults.set([showRight, showLeft, showEqual, showDifferent, showSingles].map { $0.state == .on }, forKey: Key.show)
    }

    @objc private func optionChanged() { saveOptions() }

    @objc private func showChanged() {
        saveOptions()
        refreshRows(keeping: currentEntryID)
        say(summary())
    }

    // MARK: Comparing

    @objc private func compare() {
        guard !isComparing, let controller else { return }
        let base = controller.activePane.model.directory
        func folder(_ field: NSTextField, _ suggestion: String, _ fallback: VFSPath) -> VFSPath? {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            return text == suggestion ? fallback : controller.resolve(text, relativeTo: base)
        }
        guard let left = folder(leftField, suggested.left, leftFolder) else { return report("The left folder is not a place Basil knows.") }
        guard let right = folder(rightField, suggested.right, rightFolder) else { return report("The right folder is not a place Basil knows.") }
        if left == right { return report("Choose two different folders.") }
        if !options.filter.trimmingCharacters(in: .whitespaces).isEmpty, (try? NameFilter(options.filter)) == nil {
            return report("The Files filter is not valid.")
        }
        saveOptions()
        run(left, right)
    }

    private func run(_ left: VFSPath, _ right: VFSPath) {
        guard let controller else { return }
        let registry = controller.providers
        let options = options
        entries = []
        rows = []
        marked = []
        removed = []
        compared = (left, right)
        table.reloadData()
        status.stringValue = "Comparing"
        let started = Date()
        let progress = ProgressBox()
        task = Task { [weak self] in
            let ticker = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.say("Comparing")
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let (count, folder) = progress.value
                    self?.status.stringValue = "Comparing, \(count) files so far" + (folder.isEmpty ? "" : ", in \(folder)")
                }
            }
            defer { ticker.cancel() }
            do {
                let found = try await SyncComparer.compare(left: left, right: right, options: options, registry: registry) { count, folder in
                    progress.value = (count, folder)
                }
                guard let self else { return }
                self.task = nil
                self.entries = found
                self.refreshRows(keeping: nil)
                let text = self.summary()
                self.status.stringValue = text
                self.say(text)
                if !self.rows.isEmpty {
                    self.window?.makeFirstResponder(self.table)
                    self.table.selectRowIndexes([0], byExtendingSelection: false)
                }
                _ = started
            } catch is CancellationError {
                self?.task = nil
                self?.status.stringValue = "Comparing stopped"
                self?.say("Comparing stopped")
            } catch {
                self?.task = nil
                self?.report(PaneViewController.describe(error))
            }
            self?.updateButtons()
        }
        updateButtons()
    }

    @objc private func stop() {
        task?.cancel()
    }

    /// "12 to copy to the right (30 MB), 3 to the left, 40 equal, 1 different."
    private func summary() -> String {
        let chosen = entries.filter { !removed.contains($0.id) }
        guard !chosen.isEmpty else { return entries.isEmpty ? "The folders have nothing to compare." : "Nothing left in this sync." }
        let sizes = controller?.settings.formatters.size
        func bytes(_ b: Int64) -> String { sizes?.string(b) ?? ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let right = chosen.filter { $0.action == .copyRight }, left = chosen.filter { $0.action == .copyLeft }
        let delete = chosen.filter { $0.action == .deleteRight }
        var parts: [String] = []
        if !right.isEmpty { parts.append("\(right.count) to copy to the right (\(bytes(right.reduce(0) { $0 + $1.copyBytes })))") }
        if !left.isEmpty { parts.append("\(left.count) to the left (\(bytes(left.reduce(0) { $0 + $1.copyBytes })))") }
        if !delete.isEmpty { parts.append("\(delete.count) to delete on the right") }
        let equal = chosen.filter { $0.state == .equal }.count
        let different = chosen.filter { $0.state == .different && $0.action == .none }.count
        if equal > 0 { parts.append("\(equal) equal") }
        if different > 0 { parts.append("\(different) different") }
        var text = parts.joined(separator: ", ")
        if rows.count < chosen.count { text += ". \(rows.count) shown" }
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    private func report(_ message: String) {
        status.stringValue = message
        say(message)
    }

    private func say(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Rows

    private func shown(_ entry: SyncEntry) -> Bool {
        if removed.contains(entry.id) { return false }
        if entry.state == .leftOnly || entry.state == .rightOnly {
            guard showSingles.state == .on else { return false }
        }
        switch entry.action {
        case .copyRight: return showRight.state == .on
        case .copyLeft: return showLeft.state == .on
        case .deleteRight: return showSingles.state == .on || showRight.state == .on
        case .none: return entry.state == .equal ? showEqual.state == .on : showDifferent.state == .on
        }
    }

    private var currentEntryID: Int? { rows[safe: table.selectedRow].map { entries[$0].id } }

    private func refreshRows(keeping id: Int?) {
        rows = entries.indices.filter { shown(entries[$0]) }
        table.reloadData()
        if let id, let row = rows.firstIndex(where: { entries[$0].id == id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !rows.isEmpty {
            table.selectRowIndexes([min(max(table.selectedRow, 0), rows.count - 1)], byExtendingSelection: false)
        }
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    static func actionWord(_ action: SyncAction, _ state: SyncState) -> String {
        switch action {
        case .copyRight: "Copy right"
        case .copyLeft: "Copy left"
        case .deleteRight: "Delete right"
        case .none: state == .equal ? "Equal" : "Leave"
        }
    }

    static func stateWords(_ state: SyncState) -> String {
        switch state {
        case .equal: "equal"
        case .leftNewer: "left newer"
        case .rightNewer: "right newer"
        case .different: "different"
        case .leftOnly: "only on the left"
        case .rightOnly: "only on the right"
        }
    }

    static func actionWords(_ action: SyncAction) -> String {
        switch action {
        case .copyRight: "copy to the right"
        case .copyLeft: "copy to the left"
        case .deleteRight: "delete on the right"
        case .none: "leave alone"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = rows[safe: row], let formatters = controller?.settings.formatters else { return nil }
        let entry = entries[index]
        let id = NSUserInterfaceItemIdentifier("syncRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: [nil, 90, 140, 100, 90, 140], flexibleFont: Theme.listFont)
        func size(_ item: FileItem?) -> String {
            guard let item else { return "" }
            if let files = entry.folderFiles {
                let count = files == 1 ? "1 file" : "\(files) files"
                return item.size.map { formatters.size.string($0) + ", " + count } ?? count
            }
            return item.isDirectoryLike ? "folder" : item.size.map(formatters.size.string) ?? ""
        }
        func date(_ item: FileItem?) -> String { item.map { formatters.date($0.modified) } ?? "" }
        func side(_ name: String, _ item: FileItem?) -> String {
            guard let item else { return "\(name) missing" }
            return [name + " " + size(item), date(item)].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let isMarked = marked.contains(entry.id)
        let spoken = [entry.relative + (entry.isFolder ? ", folder" : ""), Self.stateWords(entry.state), Self.actionWords(entry.action),
                      side("left", entry.left), side("right", entry.right)].joined(separator: ", ") + (isMarked ? ", selected" : "")
        cell.show([(isMarked ? "* " : "") + entry.relative, size(entry.left), date(entry.left), Self.actionWord(entry.action, entry.state),
                   size(entry.right), date(entry.right)], spoken: spoken)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompareRowBackground()
        if let index = rows[safe: row] {
            view.status = switch entries[index].action {
            case .copyRight: .onlyLeft
            case .copyLeft: .onlyRight
            case .deleteRight: .changed
            case .none: entries[index].state == .equal ? .same : .changed
            }
        }
        return view
    }

    // MARK: Changing directions

    /// The marked rows, or the cursor row when none are marked.
    private var chosenIndices: [Int] {
        let picked = entries.indices.filter { marked.contains(entries[$0].id) && !removed.contains(entries[$0].id) }
        if !picked.isEmpty { return picked }
        return rows[safe: table.selectedRow].map { [$0] } ?? []
    }

    private func set(_ action: SyncAction) {
        let chosen = chosenIndices
        guard !chosen.isEmpty else { return report("No files") }
        var changed = 0
        for i in chosen where entries[i].allows(action) {
            entries[i].action = action
            changed += 1
        }
        let keep = currentEntryID
        refreshRows(keeping: keep)
        if changed == 0 {
            report(action == .deleteRight ? "Nothing to delete on the right" : "Nothing to copy from that side")
        } else if chosen.count == 1 {
            report(Self.actionWords(action).prefix(1).uppercased() + Self.actionWords(action).dropFirst())
        } else {
            report("\(changed) files: " + Self.actionWords(action))
        }
    }

    @objc private func menuSetAction(_ sender: NSMenuItem) {
        let action: SyncAction = switch sender.representedObject as? String {
        case "right": .copyRight
        case "left": .copyLeft
        case "delete": .deleteRight
        default: .none
        }
        set(action)
    }

    @objc private func removeChosen() {
        let chosen = chosenIndices
        guard !chosen.isEmpty else { return report("No files") }
        for i in chosen { removed.insert(entries[i].id) }
        marked.subtract(chosen.map { entries[$0].id })
        let row = table.selectedRow
        refreshRows(keeping: nil)
        if !rows.isEmpty { table.selectRowIndexes([min(row, rows.count - 1)], byExtendingSelection: false) }
        report(chosen.count == 1 ? "Removed from this sync" : "\(chosen.count) files removed from this sync")
    }

    private func toggleMark() {
        guard let index = rows[safe: table.selectedRow] else { return }
        let id = entries[index].id
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
        let row = table.selectedRow
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        report((marked.contains(id) ? "Selected, " : "Deselected, ") + (marked.isEmpty ? "none" : marked.count == 1 ? "1 file" : "\(marked.count) files"))
        if row + 1 < rows.count { table.selectRowIndexes([row + 1], byExtendingSelection: false) }
    }

    // MARK: Synchronizing

    @objc private func synchronize() {
        guard !isComparing, let controller, let compared, let window else { return }
        let chosen = entries.filter { !removed.contains($0.id) && $0.action != .none }
        guard !chosen.isEmpty else { return report("Nothing to synchronize.") }
        let alert = NSAlert()
        alert.messageText = "Synchronize \(compared.left.displayName) and \(compared.right.displayName)?"
        var info = SyncOperation.summary(chosen) + "."
        if chosen.contains(where: { $0.action == .deleteRight }) { info += " Deleted files go to the Trash where the place has one." }
        alert.informativeText = info
        alert.alertStyle = chosen.contains { $0.action == .deleteRight } ? .warning : .informational
        alert.addButton(withTitle: "Synchronize")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await controller.present(alert, in: window) == 0 else { return }
            let s = controller.settings.settings
            let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries, secure: s.secureCopy)
            let item = controller.queue.add(SyncOperation(left: compared.left, right: compared.right, entries: chosen,
                                                          registry: controller.providers, options: options))
            report("Synchronizing in the queue")
            item.whenDone = { [weak self] _ in
                guard let self, self.window?.isVisible == true, self.compared?.left == compared.left else { return }
                self.run(compared.left, compared.right)
            }
        }
    }

    @objc private func closeWindow() { close() }

    // MARK: Keys

    /// Comma (or <) copies to the left, period (or >) to the right, = leaves alone, minus removes:
    /// by the character typed, so they work on every keyboard layout.
    private func handle(character: String) -> Bool {
        guard window?.firstResponder === table else { return false }
        switch character {
        case ",", "<": set(.copyLeft)
        case ".", ">": set(.copyRight)
        case "=": set(.none)
        case "-": removeChosen()
        default: return false
        }
        return true
    }

    private func handle(_ chord: KeyChord) -> Bool {
        let inList = window?.firstResponder === table
        switch chord {
        case KeyChord(.escape):
            if isComparing { stop() } else { closeWindow() }
        case KeyChord(.character("w"), .command): closeWindow()
        case KeyChord(.enter) where !inList:
            if isComparing { return false }
            compare()
        case KeyChord(.forwardDelete) where inList, KeyChord(.backspace) where inList, KeyChord(.numpad("-")) where inList:
            removeChosen()
        case KeyChord(.space) where inList: toggleMark()
        case KeyChord(.character("a"), .command) where inList:
            marked = Set(rows.map { entries[$0].id })
            table.reloadData()
            say("Selected, \(marked.count) files")
        default:
            return false
        }
        return true
    }
}

/// The comparer's running count, read by the status line.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Int, String) = (0, "")
    var value: (Int, String) {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension MainWindowController {
    /// Commands > Synchronize Directories: the left pane's folder against the right pane's.
    func synchronizeDirectories() {
        let left = Listings.info(self.left.model.directory.location)?.origin ?? self.left.model.directory
        let right = Listings.info(self.right.model.directory.location)?.origin ?? self.right.model.directory
        if syncWindow == nil {
            syncWindow = SyncWindowController(controller: self, defaults: defaults, left: left, right: right)
        }
        syncWindow?.show(left: left, right: right)
    }
}
