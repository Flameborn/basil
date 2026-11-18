import AppKit
import BasilCore
import BasilVFS

@MainActor
protocol PaneViewControllerDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: PaneViewController)
    func pane(_ pane: PaneViewController, perform chord: KeyChord) -> Bool
    func pane(_ pane: PaneViewController, announce message: String)
    func paneDidChangeDirectory(_ pane: PaneViewController)
    func paneRequestsSettings(_ pane: PaneViewController)
}

/// One side of the window: drive bar, path header, file table, quick-filter bar and status line.
@MainActor
final class PaneViewController: NSViewController {
    let side: PaneSide
    let model: PaneModel
    let settings: SettingsStore
    private let defaults: UserDefaults
    weak var delegate: PaneViewControllerDelegate?

    private let table = PaneTableView()
    private let scrollView = NSScrollView()
    private let driveBar: DriveBar
    private let header = NSTextField(labelWithString: "")
    private let headerBox = ThemedBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let filterBar = QuickFilterBar()
    /// The directory currently displayed (after a load completes).
    private var shownDirectory: VFSPath?
    private var settingsToken: UUID?

    /// The list view (Brief, Full, custom) shown in this pane.
    private(set) var viewID: String
    private var columnContext: ColumnDefinition.Context
    private var isApplyingColumns = false
    private var widthSaveTask: Task<Void, Never>?

    /// Last folder visited per volume (volume root path -> folder), for the drive menu.
    private var lastDirectoryByVolume: [String: String]

    var isActive = false {
        didSet {
            table.isActivePane = isActive
            updateHeader()
        }
    }

    init(side: PaneSide, model: PaneModel, settings: SettingsStore, defaults: UserDefaults) {
        self.side = side
        self.model = model
        self.settings = settings
        self.defaults = defaults
        self.driveBar = DriveBar(side: side)
        viewID = defaults.string(forKey: "pane.\(side.identifier).view") ?? ListView.full.id
        lastDirectoryByVolume = defaults.dictionary(forKey: "pane.\(side.identifier).volumeDirectories") as? [String: String] ?? [:]
        columnContext = ColumnDefinition.Context(formatters: settings.formatters, viewHasExtColumn: true)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let settingsToken { settings.removeHandler(settingsToken) }
    }

    var tableView: NSTableView { table }

    // MARK: View

    override func loadView() {
        // The pane container is not an accessibility element: VoiceOver lands directly on the
        // list, which is labelled just "Left pane" / "Right pane".
        let root = NSView()

        driveBar.onSelect = { [weak self] target in
            switch target {
            case .home: self?.navigate(to: .local(FileManager.default.homeDirectoryForCurrentUser.path))
            case .volume(let url): self?.switchToVolume(url)
            }
        }

        header.font = Theme.barFont
        header.lineBreakMode = .byTruncatingHead
        header.setAccessibilityLabel("Path")
        header.setAccessibilityIdentifier("pane.\(side.identifier).path")
        headerBox.addSubview(header)

        configureTable()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.paneBackground

        filterBar.isHidden = true
        filterBar.onChange = { [weak self] text, isRegex in self?.applyFilter(text: text, isRegex: isRegex) }
        filterBar.onFinish = { [weak self] cleared in self?.finishFilter(cleared: cleared) }

        statusLabel.font = Theme.barFont
        statusLabel.textColor = Theme.barText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("pane.\(side.identifier).status")
        let statusBox = ThemedBox()
        statusBox.fillColor = Theme.barBackground
        statusBox.addSubview(statusLabel)

        let stack = NSStackView(views: [driveBar, headerBox, scrollView, filterBar, statusBox])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        for v in [header, statusLabel] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            driveBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerBox.heightAnchor.constraint(equalToConstant: 22),
            header.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -6),
            header.centerYAnchor.constraint(equalTo: headerBox.centerYAnchor),
            statusBox.heightAnchor.constraint(equalToConstant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -6),
            statusLabel.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor),
        ])
        view = root

        model.onEvent = { [weak self] event in self?.handle(event) }
        model.currentCursorProvider = { [weak self] in self?.cursorPath }
        settingsToken = settings.onChange { [weak self] _ in self?.settingsChanged() }
        updateHeader()
    }

    private func configureTable() {
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.rowHeight = Theme.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.style = .plain
        table.backgroundColor = Theme.paneBackground
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.usesAutomaticRowHeights = false
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityIdentifier("pane.\(side.identifier).table")
        table.setAccessibilityLabel(side.accessibilityLabel)
        applyColumns()
        table.dataSource = self
        table.delegate = self
        table.keyDelegate = self
    }

    // MARK: Views and columns

    var currentView: ListView { settings.settings.view(id: viewID) }

    func setView(_ id: String) {
        guard settings.settings.views.contains(where: { $0.id == id }) else { return }
        viewID = id
        defaults.set(id, forKey: "pane.\(side.identifier).view")
        applyColumns()
        table.reloadData()
        delegate?.pane(self, announce: "\(currentView.name) view")
    }

    /// Rebuilds the table columns from the current view.
    private func applyColumns() {
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        let specs = currentView.visibleColumns
        for column in table.tableColumns { table.removeTableColumn(column) }
        for spec in specs {
            guard let def = ColumnCatalog.definition(spec.id) else { continue }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id.rawValue))
            column.title = def.title
            column.width = spec.width
            column.minWidth = 36
            column.headerCell.alignment = def.alignment == .trailing ? .right : .left
            column.resizingMask = .userResizingMask
            if let key = def.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            table.addTableColumn(column)
        }
        let order = model.sortOrder
        table.sortDescriptors = [NSSortDescriptor(key: order.key.rawValue, ascending: order.ascending)]
        columnContext = ColumnDefinition.Context(
            formatters: settings.formatters,
            viewHasExtColumn: specs.contains { $0.id == .ext }
        )
    }

    private func settingsChanged() {
        let wanted = currentView.visibleColumns.map(\.id.rawValue)
        let shown = table.tableColumns.map(\.identifier.rawValue)
        if wanted != shown {
            applyColumns()
        } else {
            // Same columns: only widths/formatting may have changed. Don't rebuild (the user may be dragging).
            for spec in currentView.visibleColumns {
                if let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(spec.id.rawValue)),
                   abs(column.width - spec.width) > 0.5 {
                    column.width = spec.width
                }
            }
            columnContext = ColumnDefinition.Context(formatters: settings.formatters,
                                                     viewHasExtColumn: wanted.contains(ColumnID.ext.rawValue))
        }
        table.reloadData()
        updateStatus()
    }

    /// Writes the table's column order and widths back to the view (debounced while dragging).
    private func saveColumnLayout() {
        guard !isApplyingColumns else { return }
        widthSaveTask?.cancel()
        widthSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            var view = self.currentView
            let tableOrder = self.table.tableColumns.map { ColumnID(rawValue: $0.identifier.rawValue) }
            var reordered: [ColumnSpec] = []
            for id in tableOrder {
                var spec = view.columns.first(where: { $0.id == id }) ?? ColumnSpec(id)
                spec.isVisible = true
                if let col = self.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id.rawValue)) {
                    spec.width = col.width
                }
                reordered.append(spec)
            }
            reordered += view.columns.filter { spec in !tableOrder.contains(spec.id) }
            view.columns = reordered
            if let index = self.settings.settings.views.firstIndex(where: { $0.id == view.id }) {
                self.settings.settings.views[index] = view
            }
        }
    }

    // MARK: Navigation

    var cursorRow: Int? {
        let r = table.selectedRow
        return r >= 0 && r < model.rows.count ? r : nil
    }

    var cursorPath: VFSPath? { cursorItem?.path }

    var cursorItem: FileItem? { cursorRow.map { model.rows[$0] } }

    func navigate(to directory: VFSPath, cursor: VFSPath? = nil) {
        model.load(directory, cursor: cursor)
    }

    func goToParent() {
        guard let parent = model.directory.parent else { return }
        navigate(to: parent, cursor: model.directory)
    }

    /// Enter: open directories, open files with their default app.
    func openCursor() {
        guard let item = cursorItem else { return }
        if item.isDirectoryLike {
            navigate(to: item.path)
        } else if item.path.location == .local {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path.path))
        }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        openCursor()
    }

    func moveCursor(to row: Int) {
        guard !model.rows.isEmpty else { return }
        let clamped = max(0, min(row, model.rows.count - 1))
        table.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        table.scrollRowToVisible(clamped)
    }

    // MARK: Selection (Total Commander "marking"; the cursor is separate)

    func toggleSelectionAtCursor(advance: Int = 0) {
        guard let row = cursorRow else { return }
        let item = model.rows[row]
        model.toggleSelection(item.path)
        let count = model.selected.count
        if model.selected.contains(item.path) {
            delegate?.pane(self, announce: "Selected, \(itemCount(count))")
        } else {
            delegate?.pane(self, announce: count > 0 ? "Deselected, \(itemCount(count))" : "Deselected")
        }
        if advance != 0 { moveCursor(to: row + advance) }
    }

    func setSort(_ key: SortKey) {
        let current = model.sortOrder
        let ascending = current.key == key ? !current.ascending : true
        // tableView(_:sortDescriptorsDidChange:) applies it.
        table.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
    }

    // MARK: Drive / bookmark menu

    func showLocationsMenu() {
        let menu = NSMenu(title: "\(side.accessibilityLabel) locations")
        menu.autoenablesItems = false

        func add(_ title: String, image: NSImage? = nil, action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = image
            menu.addItem(item)
        }

        add("Home") { [weak self] in self?.navigate(to: .local(FileManager.default.homeDirectoryForCurrentUser.path)) }
        for volume in DriveBar.volumes() {
            add(volume.name, image: volume.icon) { [weak self] in self?.switchToVolume(volume.url) }
        }

        let bookmarks = settings.settings.bookmarks
        if !bookmarks.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Bookmarks"))
            for bookmark in bookmarks {
                add(bookmark.name) { [weak self] in self?.navigate(to: bookmark.path) }
            }
        }
        menu.addItem(.separator())
        add("Add Current Folder to Bookmarks") { [weak self] in self?.bookmarkCurrentFolder() }
        add("Manage Bookmarks...") { [weak self] in
            guard let self else { return }
            self.delegate?.paneRequestsSettings(self)
        }

        let anchor = NSPoint(x: 4, y: headerBox.bounds.height)
        menu.popUp(positioning: menu.items.first, at: anchor, in: headerBox)
    }

    private func bookmarkCurrentFolder() {
        let dir = model.directory
        guard !settings.settings.bookmarks.contains(where: { $0.path == dir }) else {
            delegate?.pane(self, announce: "Already in bookmarks")
            return
        }
        settings.settings.bookmarks.append(Bookmark(name: dir.name, path: dir))
        delegate?.pane(self, announce: "Bookmark added")
    }

    /// Goes to the volume's root, or to the last folder visited there (unless the
    /// "go to root" setting is on or that folder no longer exists).
    func switchToVolume(_ url: URL) {
        let root = VFSPath.local(url.path)
        if !settings.settings.goToRootOnVolumeSwitch,
           let last = lastDirectoryByVolume[url.standardizedFileURL.path],
           FileManager.default.fileExists(atPath: last) {
            navigate(to: .local(last))
        } else {
            navigate(to: root)
        }
    }

    private func rememberVolumeDirectory() {
        guard model.directory.location == .local else { return }
        let url = URL(fileURLWithPath: model.directory.path)
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return }
        lastDirectoryByVolume[volume.standardizedFileURL.path] = model.directory.path
        defaults.set(lastDirectoryByVolume, forKey: "pane.\(side.identifier).volumeDirectories")
    }

    // MARK: Quick filter

    func showQuickFilter() {
        filterBar.isHidden = false
        filterBar.focus()
    }

    private func applyFilter(text: String, isRegex: Bool) {
        if text.isEmpty {
            filterBar.isInvalid = false
            model.setFilter(nil, cursor: cursorPath)
            return
        }
        do {
            let filter = try NameFilter(text, regex: isRegex)
            filterBar.isInvalid = false
            model.setFilter(filter, cursor: cursorPath)
        } catch {
            filterBar.isInvalid = true
        }
    }

    private func finishFilter(cleared: Bool) {
        if cleared {
            filterBar.reset()
            filterBar.isHidden = true
            model.setFilter(nil, cursor: cursorPath)
        } else if model.filter == nil {
            filterBar.isHidden = true
        }
        view.window?.makeFirstResponder(table)
        if !cleared, model.filter != nil {
            delegate?.pane(self, announce: "\(itemCount(model.rows.count)) shown")
        }
    }

    // MARK: Model events

    private func handle(_ event: PaneModel.Event) {
        switch event {
        case .reloaded(let cursor):
            if model.filter == nil, !filterBar.isHidden, !filterBar.isEditing {
                filterBar.reset()
                filterBar.isHidden = true
            }
            table.reloadData()
            let target = cursor.flatMap { path in model.rows.firstIndex { $0.path == path } } ?? 0
            moveCursor(to: target)
            updateHeader()
            updateStatus()
            if shownDirectory != model.directory {
                shownDirectory = model.directory
                rememberVolumeDirectory()
                delegate?.paneDidChangeDirectory(self)
            }
            if filterBar.isEditing {
                filterBar.matchCount = model.rows.count
            }
        case .selectionChanged:
            let visible = table.rows(in: table.visibleRect)
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            updateStatus()
        case .loadingChanged:
            updateStatus()
        case .failed(let error):
            // Nothing shown yet (e.g. the restored start folder is gone or unreadable): fall back
            // to the nearest readable parent, then Home, and still report the error.
            if shownDirectory == nil, let fallback = Self.fallbackDirectory(for: model.directory) {
                model.load(fallback)
            }
            NSSound.beep()
            let message = Self.describe(error)
            statusLabel.stringValue = message
            statusLabel.textColor = Theme.errorText
            delegate?.pane(self, announce: message)
        }
    }

    private static func fallbackDirectory(for directory: VFSPath) -> VFSPath? {
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        var candidate = directory.parent
        while let c = candidate, c.location == .local {
            if FileManager.default.isReadableFile(atPath: c.path), !c.isRoot { return c }
            candidate = c.parent
        }
        return directory == home ? nil : home
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case VFSError.permissionDenied(let path):
            "Access denied to \(path.name). Basil may need Full Disk Access, in System Settings, Privacy and Security."
        case VFSError.notFound(let path): "\(path.name) no longer exists."
        case VFSError.notADirectory(let path): "\(path.name) is not a folder."
        default: "Error: \(error.localizedDescription)"
        }
    }

    private func updateHeader() {
        header.stringValue = model.directory.description
        headerBox.fillColor = isActive ? Theme.headerActiveBackground : Theme.headerInactiveBackground
        header.textColor = isActive ? Theme.headerActiveText : Theme.headerInactiveText
    }

    /// The status line text; also what Cmd+I reads.
    var statusText: String {
        if model.isLoading { return "Loading..." }
        let size = settings.formatters.size
        var files = 0, dirs = 0, selFiles = 0, selDirs = 0
        var totalBytes: Int64 = 0, selBytes: Int64 = 0
        for item in model.rows {
            let isSel = model.selected.contains(item.path)
            if item.isDirectoryLike {
                dirs += 1
                if isSel { selDirs += 1 }
            } else {
                files += 1
                totalBytes += item.size ?? 0
                if isSel { selFiles += 1; selBytes += item.size ?? 0 }
            }
        }
        var text = "\(size.string(selBytes)) of \(size.string(totalBytes)) in \(selFiles) of \(files) files, \(selDirs) of \(dirs) folders selected"
        if let filter = model.filter { text += ", filter \(filter.text)" }
        if model.showHidden { text += ", hidden files shown" }
        return text
    }

    private func updateStatus() {
        statusLabel.textColor = Theme.barText
        statusLabel.stringValue = statusText
    }
}

// MARK: - Table data source / delegate

extension PaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let rowView = tableView.makeView(withIdentifier: id, owner: nil) as? PaneRowView ?? {
            let v = PaneRowView()
            v.identifier = id
            return v
        }()
        rowView.isAlternate = row % 2 == 1
        rowView.isActivePane = isActive
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < model.rows.count,
              let def = ColumnCatalog.definition(ColumnID(rawValue: column.identifier.rawValue)) else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? PaneCellView
            ?? makeCell(column.identifier, alignment: def.alignment)
        let item = model.rows[row]
        let isSelected = model.selected.contains(item.path)
        let text = def.text(item, columnContext)

        cell.textField?.stringValue = text
        if def.id == .name { cell.imageView?.image = Icons.icon(for: item) }
        cell.style = item.isHidden ? .hidden : (item.isDirectoryLike ? .directory : .normal)
        cell.isSelectedItem = isSelected
        cell.textField?.font = def.alignment == .trailing || def.id == .modified || def.id == .created
            ? Theme.listDigitsFont
            : (cell.style == .directory && def.id == .name ? Theme.listBoldFont : Theme.listFont)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, alignment: ColumnDefinition.Alignment) -> PaneCellView {
        let cell = PaneCellView()
        cell.identifier = id
        let field = CellTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = alignment == .trailing ? .right : .left
        cell.addSubview(field)
        cell.textField = field
        var leading = field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id.rawValue == ColumnID.name.rawValue {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4)
        }
        NSLayoutConstraint.activate([
            leading,
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingColumns,
              let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
        model.setSortOrder(ListSortOrder(key: key, ascending: d.ascending), cursor: cursorPath)
        delegate?.pane(self, announce: "Sorted by \(key.spokenName), \(d.ascending ? "ascending" : "descending")")
    }

    func tableViewColumnDidResize(_ notification: Notification) { saveColumnLayout() }
    func tableViewColumnDidMove(_ notification: Notification) { saveColumnLayout() }
}

// MARK: - Keys

extension PaneViewController: PaneTableViewKeyDelegate {
    func paneTable(_ table: PaneTableView, perform chord: KeyChord) -> Bool {
        delegate?.pane(self, perform: chord) ?? false
    }

    func paneTable(_ table: PaneTableView, typeAhead text: String) {
        let needle = text.lowercased()
        if let row = model.rows.firstIndex(where: { $0.name.lowercased().hasPrefix(needle) }) {
            moveCursor(to: row)
        } else {
            NSSound.beep()
        }
    }

    /// Reads like the visible columns: "song, selected, mp3, 1.5 MB, ...". A column's spoken text
    /// replaces its visible text when given ("" silences it, e.g. a folder's empty extension).
    func paneTable(_ table: PaneTableView, spokenTextForRow row: Int) -> String {
        guard row < model.rows.count else { return "" }
        let item = model.rows[row]
        var parts: [String] = []
        for column in table.tableColumns {
            guard let def = ColumnCatalog.definition(ColumnID(rawValue: column.identifier.rawValue)) else { continue }
            let text = def.spoken(item, columnContext) ?? def.text(item, columnContext)
            if !text.isEmpty { parts.append(text) }
            if def.id == .name, model.selected.contains(item.path) { parts.append("selected") }
        }
        return parts.joined(separator: ", ")
    }

    func paneTableDidBecomeFirstResponder(_ table: PaneTableView) {
        delegate?.paneDidBecomeActive(self)
    }
}

enum PaneSide: CaseIterable {
    case left, right

    var accessibilityLabel: String {
        switch self {
        case .left: "Left pane"
        case .right: "Right pane"
        }
    }

    var identifier: String {
        switch self {
        case .left: "left"
        case .right: "right"
        }
    }
}

extension SortKey {
    var spokenName: String {
        switch self {
        case .name: "name"
        case .ext: "extension"
        case .size: "size"
        case .modified: "date"
        case .created: "creation date"
        }
    }
}

/// A menu item that runs a closure (for menus built on the fly).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
