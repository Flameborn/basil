import AppKit
import BasilCore
import BasilVFS

@MainActor
protocol PaneViewControllerDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: PaneViewController)
    func pane(_ pane: PaneViewController, perform chord: KeyChord) -> Bool
    func pane(_ pane: PaneViewController, announce message: String)
    func paneDidChangeDirectory(_ pane: PaneViewController)
}

/// One side of the window: drive bar, path header, file table, quick-filter bar and status line.
@MainActor
final class PaneViewController: NSViewController {
    let side: PaneSide
    let model: PaneModel
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

    private static let columns: [(id: String, title: String, width: CGFloat, sort: SortKey, align: NSTextAlignment)] = [
        ("name", "Name", 260, .name, .left),
        ("ext", "Ext", 52, .ext, .left),
        ("size", "Size", 96, .size, .right),
        ("date", "Date", 128, .modified, .left),
        ("attr", "Attr", 82, .name, .left),
    ]

    var isActive = false {
        didSet {
            table.isActivePane = isActive
            updateHeader()
        }
    }

    init(side: PaneSide, model: PaneModel) {
        self.side = side
        self.model = model
        self.driveBar = DriveBar(side: side)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var tableView: NSTableView { table }

    // MARK: View

    override func loadView() {
        // The pane container is not an accessibility element: VoiceOver should land directly
        // on the list, which is labelled just "Left pane" / "Right pane".
        let root = NSView()

        driveBar.onSelect = { [weak self] url in
            self?.navigate(to: .local(url.path))
        }

        header.font = Theme.barFont
        header.lineBreakMode = .byTruncatingHead
        header.setAccessibilityElement(false) // the table's label carries the path for VoiceOver
        headerBox.addSubview(header)

        configureTable()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
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
        updateHeader()
    }

    private func configureTable() {
        for col in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = 36
            column.headerCell.alignment = col.align
            if col.id != "attr" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: col.sort.rawValue, ascending: true)
            }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = Theme.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.style = .plain
        table.backgroundColor = Theme.paneBackground
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.usesAutomaticRowHeights = false
        table.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]
        table.dataSource = self
        table.delegate = self
        table.keyDelegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityIdentifier("pane.\(side.identifier).table")
        table.setAccessibilityLabel(side.accessibilityLabel)
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

    func toggleMarkAtCursor(advance: Int = 0) {
        guard let row = cursorRow else { return }
        let item = model.rows[row]
        model.toggleMark(item.path)
        let state = model.marked.contains(item.path) ? "marked" : "unmarked"
        delegate?.pane(self, announce: "\(item.name) \(state), \(model.marked.count) marked")
        if advance != 0 { moveCursor(to: row + advance) }
    }

    func setSort(_ key: SortKey) {
        let current = model.sortOrder
        let order = ListSortOrder(key: key, ascending: current.key == key ? !current.ascending : true)
        table.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: order.ascending)]
        // tableView(_:sortDescriptorsDidChange:) applies it.
    }

    // MARK: Quick filter

    func showQuickFilter() {
        filterBar.isHidden = false
        filterBar.focus()
        delegate?.pane(self, announce: "Filter")
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
            delegate?.pane(self, announce: "\(visibleItemCount) matches")
        }
    }

    private var visibleItemCount: Int { model.rows.count }

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
                delegate?.paneDidChangeDirectory(self)
            }
            if filterBar.isEditing {
                filterBar.matchCount = visibleItemCount
            }
        case .marksChanged:
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

    /// Spoken after navigation, e.g. "Documents, 42 items".
    var directorySummary: String {
        "\(model.directory.name == "/" ? "Root" : model.directory.name), \(visibleItemCount) items"
    }

    private func updateHeader() {
        let path = model.directory.description
        header.stringValue = path
        headerBox.fillColor = isActive ? Theme.headerActiveBackground : Theme.headerInactiveBackground
        header.textColor = isActive ? Theme.headerActiveText : Theme.headerInactiveText
    }

    private func updateStatus() {
        statusLabel.textColor = Theme.barText
        if model.isLoading {
            statusLabel.stringValue = "Loading..."
            return
        }
        // Counts cover what is shown (hidden files and filtered-out items excluded), like Total Commander.
        let files = model.rows.filter { !$0.isDirectoryLike }
        let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let marked = model.markedItems
        let markedBytes = marked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var text = "\(Formatting.humanBytes(markedBytes)) of \(Formatting.humanBytes(totalBytes)) in \(marked.count) of \(files.count) files marked"
        if let filter = model.filter {
            text += ", filter \(filter.text): \(visibleItemCount) shown"
        }
        if model.showHidden { text += ", hidden files shown" }
        statusLabel.stringValue = text
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
        guard let column = tableColumn, row < model.rows.count else { return nil }
        let id = column.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaneCellView ?? makeCell(id)

        let item = model.rows[row]
        let text: String
        var accessibility: String?
        let split = item.nameAndExtension
        switch id.rawValue {
        case "name":
            text = item.isDirectoryLike ? item.name : split.base
            cell.imageView?.image = Formatting.icon(for: item)
            let marked = model.marked.contains(item.path) ? ", marked" : ""
            accessibility = "\(item.name), \(Formatting.kindDescription(item))\(marked)"
        case "ext": text = item.isDirectoryLike ? "" : split.ext
        case "size":
            text = Formatting.size(item)
            accessibility = Formatting.spokenSize(item)
        case "date": text = Formatting.date(item.modified)
        default: text = Formatting.attributes(item)
        }
        cell.style = item.isHidden ? .hidden : (item.isDirectoryLike ? .directory : .normal)
        cell.isMarked = model.marked.contains(item.path)
        cell.textField?.stringValue = text
        cell.textField?.font = (id.rawValue == "size" || id.rawValue == "date") ? Theme.listDigitsFont
            : (cell.style == .directory && id.rawValue == "name" ? Theme.listBoldFont : Theme.listFont)
        cell.spokenLabel = accessibility
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> PaneCellView {
        let cell = PaneCellView()
        cell.identifier = id
        let field = CellTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = Self.columns.first { $0.id == id.rawValue }?.align ?? .left
        cell.addSubview(field)
        cell.textField = field
        var leading = field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id.rawValue == "name" {
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
        guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
        model.setSortOrder(ListSortOrder(key: key, ascending: d.ascending), cursor: cursorPath)
        delegate?.pane(self, announce: "Sorted by \(key.spokenName), \(d.ascending ? "ascending" : "descending")")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Keep the cursor visible after keyboard moves; nothing else to do - the cursor is the selection.
    }
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
        }
    }
}
