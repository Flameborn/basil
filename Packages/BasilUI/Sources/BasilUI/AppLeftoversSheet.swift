import AppKit
import BasilCore
import BasilIntegrations
import BasilOperations
import BasilVFS

/// ForkLift-style app cleanup. After F8 / Shift+F8 removes an .app (and no other copy of it is
/// installed), Basil looks for what it left behind (`AppLeftoverFinder`, BasilIntegrations) and
/// shows a checklist: everything ticked, except group containers another installed app also uses.
/// Space ticks or unticks the cursor row; Return removes the ticked items the way the app went
/// (Trash or permanently) as one queue item; Escape keeps everything. Items that need an
/// administrator are removed after one macOS password prompt.
/// Files > Delete > Find App Leftovers does the same for the cursor app (which stays), or for an
/// app that is already gone, by its name or bundle ID.
extension MainWindowController {
    /// The apps among items about to be removed, read before they go.
    func appIdentities(in items: [FileItem]) -> [AppIdentity] {
        items.compactMap { item in
            guard item.path.location == .local, item.isDirectoryLike, item.name.lowercased().hasSuffix(".app") else { return nil }
            return AppIdentity.read(appAt: URL(fileURLWithPath: item.path.path))
        }
    }

    /// Called when the removal of `apps` has run.
    func offerLeftovers(of apps: [AppIdentity], toTrash: Bool) {
        let finder = AppLeftoverFinder(roots: leftoverRoots)
        Task {
            for app in apps {
                let found = await Task.detached { AppCleanup.leftoversOfRemovedApp(app, finder: finder) }.value
                guard let found, !found.isEmpty else { continue }
                await showLeftovers(found, of: app, toTrash: toTrash)
            }
        }
    }

    /// Files > Delete > Find App Leftovers.
    func findAppLeftovers() {
        if let item = activePane.cursorItem, let app = appIdentities(in: [item]).first {
            return searchAndShow(app, toTrash: true)
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Find leftovers of an app"
        alert.informativeText = "Put the cursor on an app to find its leftovers, or type the name or bundle ID of an app that is already gone (for example \"Leftie\" or \"com.example.Leftie\")."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.setAccessibilityLabel("App name or bundle ID")
        field.placeholderString = "App name or bundle ID"
        alert.accessoryView = field
        alert.addButton(withTitle: "Find")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        Task {
            guard await present(alert, in: window) == 0 else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let isID = text.contains(".") && !text.contains(" ")
            let name = isID ? (text.split(separator: ".").last.map(String.init) ?? text) : text
            let app = AppIdentity(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                                  bundleID: isID ? text : "", names: isID ? [] : [text], executables: isID ? [] : [text])
            searchAndShow(app, toTrash: true)
        }
    }

    private func searchAndShow(_ app: AppIdentity, toTrash: Bool) {
        let finder = AppLeftoverFinder(roots: leftoverRoots)
        Task {
            let found = await Task.detached { finder.find(for: app) }.value
            if found.isEmpty { return announce("No leftovers of \(app.displayName) found") }
            await showLeftovers(found, of: app, toTrash: toTrash)
        }
    }

    /// Shows the checklist once no other sheet is up.
    private func showLeftovers(_ leftovers: [AppLeftover], of app: AppIdentity, toTrash: Bool) async {
        guard let window else { return }
        while window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(300)) }
        let controller = LeftoversViewController(app: app, leftovers: leftovers, toTrash: toTrash, size: settings.settings.size)
        let sheet = EscapableSheet(contentViewController: controller)
        sheet.title = "Leftovers of \(app.displayName)"
        let pane = activePane
        let chosen: [AppLeftover]? = await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: [AppLeftover]?) {
                guard !resumed else { return }
                resumed = true
                window.endSheet(sheet)
                continuation.resume(returning: value)
            }
            sheet.onCancel = { finish(nil) }
            controller.onDone = { finish($0) }
            window.beginSheet(sheet) { [weak window] _ in window?.makeFirstResponder(pane.tableView) }
        }
        guard let chosen, !chosen.isEmpty else { return }
        let normal = chosen.filter { !$0.needsAdmin }.map { VFSPath.local($0.url.path) }
        let admin = chosen.filter(\.needsAdmin).map { VFSPath.local($0.url.path) }
        queue.add(RemoveLeftoversOperation(appName: app.displayName, paths: normal, adminPaths: admin,
                                           toTrash: toTrash, registry: providers, administratorFiles: administratorFiles))
    }
}

extension AppIdentity {
    /// "Leftie" for Leftie.app.
    var displayName: String {
        let file = bundleURL.deletingPathExtension().lastPathComponent
        return file.isEmpty ? bundleID : file
    }
}

/// The checklist: a message, a table with one checkbox per item, and the buttons.
@MainActor
final class LeftoversViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let columns = ["Item", "Kind", "Size"]
    let app: AppIdentity
    let leftovers: [AppLeftover]
    let toTrash: Bool
    let size: SizeFormat
    private(set) var ticked: [Bool]
    var onDone: ([AppLeftover]?) -> Void = { _ in }
    private let table = LeftoversTable()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var removeButton: NSButton!

    init(app: AppIdentity, leftovers: [AppLeftover], toTrash: Bool, size: SizeFormat) {
        self.app = app
        self.leftovers = leftovers
        self.toTrash = toTrash
        self.size = size
        ticked = leftovers.map { $0.sharedWith == nil }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 440))
        let title = NSTextField(labelWithString: "\(app.displayName) left these items behind")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        title.setAccessibilityRole(.staticText)

        for name in Self.columns {
            // Accessibility names a cell after its column identifier, so identifiers are words.
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = name == "Item" ? 460 : (name == "Kind" ? 190 : 80)
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Leftovers")
        table.setAccessibilityIdentifier("leftovers.table")
        table.dataSource = self
        table.delegate = self
        table.onToggle = { [weak self] in self?.toggleCursorRow() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        summary.textColor = Theme.secondaryText
        removeButton = NSButton(title: toTrash ? "Move to Trash" : "Delete", target: self, action: #selector(remove))
        removeButton.keyEquivalent = "\r"
        let keep = NSButton(title: "Keep All", target: self, action: #selector(keepAll))
        keep.keyEquivalent = "\u{1b}"
        let all = NSButton(title: "Check All", target: self, action: #selector(checkAll))
        let none = NSButton(title: "Uncheck All", target: self, action: #selector(uncheckAll))

        let buttons = NSStackView(views: [all, none, NSView(), keep, removeButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.views[2].setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [title, summary, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        view = root
        updateSummary()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        table.selectRowIndexes([0], byExtendingSelection: false)
        view.window?.makeFirstResponder(table)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { leftovers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, leftovers.indices.contains(row) else { return nil }
        let item = leftovers[row]
        if id == "Item" {
            let box = NSButton(checkboxWithTitle: Self.displayPath(item.url), target: self, action: #selector(boxClicked(_:)))
            box.state = ticked[row] ? .on : .off
            box.tag = row
            box.lineBreakMode = .byTruncatingMiddle
            // Spoken shorter than the shown path; the Kind column says which Library it is in.
            box.setAccessibilityLabel(Self.spokenName(item.url))
            return box
        }
        let text = id == "Kind" ? kindText(item) : size.string(item.size)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel(text)
        if id == "Kind", item.needsAdmin || item.sharedWith != nil { label.textColor = Theme.secondaryText }
        return label
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    private func kindText(_ item: AppLeftover) -> String {
        var parts = [item.kind]
        if item.matchedByName { parts.append("found by name") }
        if let other = item.sharedWith { parts.append("also used by \(other)") }
        if item.needsAdmin { parts.append("needs administrator rights") }
        return parts.joined(separator: ", ")
    }

    /// "com.example.App, in Caches".
    static func spokenName(_ url: URL) -> String {
        "\(url.lastPathComponent), in \(url.deletingLastPathComponent().lastPathComponent)"
    }

    /// "~/Library/Caches/com.example.App".
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Actions

    @objc private func boxClicked(_ sender: NSButton) {
        guard ticked.indices.contains(sender.tag) else { return }
        ticked[sender.tag] = sender.state == .on
        updateSummary()
    }

    private func toggleCursorRow() {
        let row = table.selectedRow
        guard ticked.indices.contains(row) else { return }
        ticked[row].toggle()
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        updateSummary()
        announce(ticked[row] ? "Checked" : "Unchecked")
    }

    @objc private func checkAll() { setAll(true) }
    @objc private func uncheckAll() { setAll(false) }

    private func setAll(_ value: Bool) {
        ticked = ticked.map { _ in value }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<leftovers.count), columnIndexes: [0])
        updateSummary()
        announce(value ? "All checked" : "All unchecked")
    }

    @objc private func remove() {
        let chosen = zip(leftovers, ticked).filter(\.1).map(\.0)
        guard !chosen.isEmpty else { return NSSound.beep() }
        onDone(chosen)
    }

    @objc private func keepAll() { onDone(nil) }

    private func updateSummary() {
        let chosen = zip(leftovers, ticked).filter(\.1).map(\.0)
        let total = chosen.reduce(Int64(0)) { $0 + $1.size }
        let where_ = toTrash ? "moved to the Trash" : "deleted permanently"
        var text = "\(chosen.count) of \(leftovers.count) checked, \(size.string(total)). Checked items are \(where_)."
        if chosen.contains(where: \.needsAdmin) { text += " Some need an administrator password." }
        summary.stringValue = text
        removeButton?.isEnabled = !chosen.isEmpty
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Space ticks or unticks the cursor row.
final class LeftoversTable: NSTableView {
    var onToggle: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            return onToggle()
        }
        super.keyDown(with: event)
    }
}
