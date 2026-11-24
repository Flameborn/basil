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
    func paneCursorDidChange(_ pane: PaneViewController)
    /// What the column annotators say about the shown folder changed (the Git branch).
    func paneDidUpdateAnnotations(_ pane: PaneViewController)
    /// The context menu for the pane's cursor item (right click, VO+Shift+M, Shift+F10).
    func paneContextMenu(_ pane: PaneViewController) -> NSMenu?
}

/// One side of the window: drive bar, path header, file table, quick-filter bar and status line.
@MainActor
final class PaneViewController: NSViewController {
    let side: PaneSide
    let model: PaneModel
    let settings: SettingsStore
    let defaults: UserDefaults
    weak var delegate: PaneViewControllerDelegate?

    /// Folder tabs (`PaneTabs.swift`). The active tab's live state is in `model`.
    var tabs: [PaneTab] = []
    var activeTabIndex = 0
    lazy var tabBar = TabBar(side: side)
    /// False when start folders were forced (UI tests): tabs are then neither restored nor saved.
    var persistsTabs = true

    private let table = PaneTableView()
    private let scrollView = NSScrollView()
    private let driveBar: DriveBar
    private lazy var pathBar = PathBar(identifier: "pane.\(side.identifier).path")
    private let statusLabel = NSTextField(labelWithString: "")
    private let filterBar = QuickFilterBar()
    /// The command line (Left or Right), `CommandLineBar.swift`.
    private(set) lazy var commandBar = CommandLineBar(defaults: defaults)
    /// The directory currently displayed (after a load completes).
    private var shownDirectory: VFSPath?
    private var settingsToken: UUID?

    /// The list view (Brief, Full, custom) shown in this pane.
    private(set) var viewID: String
    private var columnContext: ColumnDefinition.Context
    /// What the column annotators (Git status) said about the shown folder, by column.
    private var annotations: [ColumnID: ColumnAnnotation] = [:]
    /// What the Git annotator said about the shown folder; nil outside a working tree.
    var gitAnnotation: ColumnAnnotation? { annotations[.git] }
    private var annotationTask: Task<Void, Never>?
    private var annotationGeneration = 0
    /// Watches what the annotators named (a repository's .git folder) while this folder is shown.
    private var annotationWatch: (paths: [String], task: Task<Void, Never>)?
    private var isApplyingColumns = false
    private var widthSaveTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

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
        columnContext = ColumnDefinition.Context(formatters: settings.formatters)
        super.init(nibName: nil, bundle: nil)
        tabs = [PaneTab(directory: model.directory, sort: model.sortOrder, viewID: viewID)]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let settingsToken { settings.removeHandler(settingsToken) }
        annotationWatch?.task.cancel()
    }

    var tableView: NSTableView { table }
    var paneTable: PaneTableView { table }

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

        pathBar.onSelect = { [weak self] segment, next in self?.goToPathSegment(segment, next: next) }
        pathBar.onLeave = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(table)
        }

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

        commandBar.isHidden = true
        commandBar.onClose = { [weak self] in self?.hideCommandLine() }
        commandBar.cursorText = { [weak self] fullPath in
            guard let self, let item = cursorItem else { return nil }
            return CommandLineBar.shellQuoted(fullPath ? item.path.path : item.name)
        }

        statusLabel.font = Theme.barFont
        statusLabel.textColor = Theme.barText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("pane.\(side.identifier).status")
        let statusBox = ThemedBox()
        statusBox.fillColor = Theme.barBackground
        statusBox.addSubview(statusLabel)

        tabBar.onSelect = { [weak self] index in self?.switchToTab(index) }
        tabBar.isHidden = true
        let stack = NSStackView(views: [driveBar, tabBar, pathBar, scrollView, filterBar, commandBar, statusBox])
        stack.detachesHiddenViews = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        for v in [statusLabel] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            driveBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 22),
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

    /// Switching tabs: the tab's view and sort order, without speech (the tab is announced).
    func applyTabView(_ id: String, sort: ListSortOrder) {
        if settings.settings.views.contains(where: { $0.id == id }) {
            viewID = id
            defaults.set(id, forKey: "pane.\(side.identifier).view")
        }
        model.prepareSortOrder(sort)
        applyColumns()
        table.reloadData()
    }

    /// The view's visible columns, without those shown only where an annotator answered (the
    /// Git column outside a repository).
    private var shownColumns: [ColumnSpec] {
        currentView.visibleColumns.filter { spec in
            guard let def = ColumnCatalog.definition(spec.id) else { return false }
            return !def.onlyWhenAnnotated || annotations[spec.id] != nil
        }
    }

    private func makeColumnContext() -> ColumnDefinition.Context {
        ColumnDefinition.Context(formatters: settings.formatters, annotations: annotations,
                                 namesRelativeTo: Listings.info(model.directory.location)?.origin)
    }

    /// Asks the column annotators about the shown folder again, shortly (folder loads and
    /// watcher changes come in bursts). Stale answers (another folder, a newer refresh) are
    /// dropped. Also called after queue items and when Basil comes to the front: git state can
    /// change outside the folder (a commit in a terminal).
    func refreshAnnotations(after delay: Duration = .milliseconds(150)) {
        annotationTask?.cancel()
        annotationGeneration += 1
        let generation = annotationGeneration
        let directory = model.directory
        let registry = model.registry
        guard !registry.columnAnnotators.isEmpty else { return }
        annotationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await Task.detached { await registry.annotations(for: directory) }.value
            guard let self, generation == self.annotationGeneration, directory == self.model.directory else { return }
            self.apply(annotations: result)
        }
    }

    private func apply(annotations new: [ColumnID: ColumnAnnotation]) {
        watchAnnotationSources(Array(Set(new.values.flatMap(\.watch))).sorted())
        guard new != annotations else { return }
        let before = shownColumns.map(\.id)
        annotations = new
        columnContext = makeColumnContext()
        delegate?.paneDidUpdateAnnotations(self)
        if shownColumns.map(\.id) != before {
            applyColumns()
            table.reloadData()
        } else {
            let visible = table.rows(in: table.visibleRect)
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    /// Asks the annotators again whenever what they named changes (a commit made in a terminal
    /// changes .git). Stops once the pane shows a folder outside the repository.
    private func watchAnnotationSources(_ paths: [String]) {
        guard paths != annotationWatch?.paths else { return }
        annotationWatch?.task.cancel()
        annotationWatch = nil
        guard !paths.isEmpty else { return }
        let task = Task { [weak self] in
            for await _ in TreeWatcher.changes(in: paths) {
                guard let self, !Task.isCancelled else { return }
                self.refreshAnnotations(after: .milliseconds(300))
            }
        }
        annotationWatch = (paths, task)
    }

    /// Rebuilds the table columns from the current view.
    private func applyColumns() {
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        let specs = shownColumns
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
        columnContext = makeColumnContext()
    }

    private func settingsChanged() {
        let wanted = shownColumns.map(\.id.rawValue)
        let shown = table.tableColumns.map(\.identifier.rawValue)
        if wanted != shown {
            applyColumns()
        } else {
            // Same columns: only widths/formatting may have changed. Don't rebuild (the user may be dragging).
            for spec in shownColumns {
                if let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(spec.id.rawValue)),
                   abs(column.width - spec.width) > 0.5 {
                    column.width = spec.width
                }
            }
            columnContext = makeColumnContext()
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
            // Columns not in the table (hidden ones, the Git column outside a repository) keep
            // their place after the column they followed.
            for (index, spec) in view.columns.enumerated() where !tableOrder.contains(spec.id) {
                let previous = view.columns[..<index].last { prev in reordered.contains { $0.id == prev.id } }
                let at = previous.flatMap { prev in reordered.firstIndex { $0.id == prev.id } }.map { $0 + 1 } ?? 0
                reordered.insert(spec, at: at)
            }
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
        // A locked tab keeps its folder: another folder opens in a new tab (TC).
        if activeTab.locked, directory != model.directory, shownDirectory != nil {
            return newTab(at: directory, cursor: cursor)
        }
        model.load(directory, cursor: cursor)
    }

    /// Backspace: the parent folder. At the root of an archive, the folder holding the archive,
    /// with the cursor on it.
    func goToParent() {
        if let listing = Listings.info(model.directory.location) {
            // Search results: back to the folder searched.
            navigate(to: listing.origin, cursor: cursorPath.flatMap { listing.origin.childLeading(to: $0) })
        } else if let parent = model.directory.parent {
            navigate(to: parent, cursor: model.directory)
        } else if let container = model.directory.location.container, let folder = container.parent {
            navigate(to: folder, cursor: container)
        }
    }

    /// Enter: open directories, enter archives (Total Commander), open other files with their default app.
    func openCursor() {
        guard let item = cursorItem else { return }
        if let local = packagePath(of: item) {
            // An app or a document package opens like in Finder; Cmd+PageDown or
            // Show Package Contents goes inside.
            NSWorkspace.shared.open(URL(fileURLWithPath: local))
        } else if item.isDirectoryLike {
            navigate(to: item.path)
        } else if model.registry.isContainer(item) {
            openContainer(item, byContent: false)
        } else if let local = model.registry.localPath(of: item.path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: local.path))
        }
    }

    /// The local path of `item` when it is a macOS package (an app, or a folder macOS treats as one
    /// document, like .rtfd), on a local disk or a mounted share.
    func packagePath(of item: FileItem) -> String? {
        guard item.isDirectoryLike, let local = model.registry.localPath(of: item.path) else { return nil }
        return NSWorkspace.shared.isFilePackage(atPath: local.path) ? local.path : nil
    }

    /// Show Package Contents: enters the cursor folder even when it is a package.
    func enterCursorFolder() {
        guard let item = cursorItem, item.isDirectoryLike else { return }
        navigate(to: item.path)
    }

    /// Cmd+PageDown (Total Commander's Ctrl+PageDown): enters the cursor file as an archive
    /// whatever its name, when its content is a format Basil reads (docx, jar, apk are zip files).
    /// On a folder (also a package such as an app) it goes inside.
    func openCursorAsContainer() {
        guard let item = cursorItem else { return }
        guard case .file = item.kind else {
            if item.isDirectoryLike { navigate(to: item.path) }
            return
        }
        openContainer(item, byContent: true)
    }

    private func openContainer(_ item: FileItem, byContent: Bool) {
        let registry = model.registry
        Task {
            do {
                if let root = try await registry.openContainer(item, byContent: byContent) {
                    navigate(to: root)
                } else {
                    report("\(item.name) is not an archive Basil can open")
                }
            } catch {
                report(Self.describe(error))
            }
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

    /// Space (and Shift+Up/Down). With `calculateSize` and the "Space calculates folder sizes"
    /// setting, selecting a folder also calculates its size (Total Commander's option).
    func toggleSelectionAtCursor(advance: Int = 0, calculateSize: Bool = false) {
        guard let row = cursorRow else { return }
        let item = model.rows[row]
        model.toggleSelection(item.path)
        let count = model.selected.count
        if model.selected.contains(item.path) {
            delegate?.pane(self, announce: "Selected, \(itemCount(count))")
            if calculateSize, settings.settings.spaceCalculatesFolderSizes { calculateSizeOnSelect(item) }
        } else {
            delegate?.pane(self, announce: count > 0 ? "Deselected, \(itemCount(count))" : "Deselected")
        }
        if advance != 0 { moveCursor(to: row + advance) }
    }

    // MARK: Folder sizes (Total Commander: calculate occupied space)

    /// Cmd+Shift+S: calculates the size of the folders among `items` and speaks the result.
    /// "Calculating" is only said when it takes more than a second.
    func calculateSizes(of items: [FileItem]) {
        let folders = items.filter(\.isDirectoryLike)
        guard !folders.isEmpty else {
            delegate?.pane(self, announce: "No folders")
            return
        }
        sizeTask?.cancel()
        sizeTask = Task { [weak self] in
            let notice = Task { [weak self] in
                try await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.delegate?.pane(self, announce: "Calculating")
            }
            defer { notice.cancel() }
            guard let self else { return }
            do {
                let results = try await self.model.calculateSizes(of: folders.map(\.path))
                notice.cancel()
                self.delegate?.pane(self, announce: self.describeTotals(results, folders: folders))
                self.updateStatus()
            } catch is CancellationError {
            } catch {
                self.delegate?.pane(self, announce: Self.describe(error))
            }
        }
    }

    /// Folders selected with Space wait here and are calculated one after another, so the Size
    /// column gets every result. Only the last one's size is spoken ("Alpha, 1.5 MB"), and only
    /// while it is still selected.
    private var spaceSizeQueue: [FileItem] = []
    private var spaceSizeTask: Task<Void, Never>?
    private var spaceSizeRun = 0

    private func calculateSizeOnSelect(_ item: FileItem) {
        guard item.isDirectoryLike, model.folderSizes[item.path] == nil,
              !spaceSizeQueue.contains(where: { $0.path == item.path }) else { return }
        spaceSizeQueue.append(item)
        guard spaceSizeTask == nil else { return }
        spaceSizeRun += 1
        let run = spaceSizeRun
        spaceSizeTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.spaceSizeQueue.isEmpty {
                let next = self.spaceSizeQueue.removeFirst()
                guard next.path.parent == self.model.directory else { continue }
                guard let totals = try? await self.model.calculateSizes(of: [next.path])[next.path] else { continue }
                guard !Task.isCancelled else { break }
                self.updateStatus()
                if self.spaceSizeQueue.isEmpty, self.model.selected.contains(next.path) {
                    self.delegate?.pane(self, announce: "\(next.name), \(self.settings.formatters.size.string(totals.bytes))")
                }
            }
            if let self, self.spaceSizeRun == run { self.spaceSizeTask = nil }
        }
    }

    private func cancelSpaceSizes() {
        spaceSizeQueue.removeAll()
        spaceSizeTask?.cancel()
        spaceSizeTask = nil
    }

    /// "Alpha, 1.5 MB, 120 files, 8 folders" or "3 folders, 4.2 GB, 1,200 files, 30 folders".
    private func describeTotals(_ results: [VFSPath: DirectoryTotals], folders: [FileItem]) -> String {
        let total = results.values.reduce(DirectoryTotals(), +)
        let size = settings.formatters.size.string(total.bytes)
        func count(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }
        var text = folders.count == 1 ? "\(folders[0].name), \(size)" : "\(count(folders.count, "folder")), \(size)"
        text += ", \(count(total.files, "file")), \(count(total.folders, "folder"))"
        if total.unreadable > 0 { text += ", \(count(total.unreadable, "folder")) could not be read" }
        return text
    }

    func setSort(_ key: SortKey) {
        let current = model.sortOrder
        // Pressing the active key again reverses the order (TC); unsorted has no direction.
        let ascending = current.key == key && key != .unsorted ? !current.ascending : true
        // tableView(_:sortDescriptorsDidChange:) applies it.
        table.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
    }

    // MARK: Drive / bookmark menu

    /// Pops up `menu` under the cursor row (or at the top of the list when there is none).
    func popUpMenuAtCursor(_ menu: NSMenu) {
        let row = cursorRow ?? 0
        let rect = model.rows.isEmpty ? .zero : table.rect(ofRow: row)
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: rect.minX + 24, y: rect.maxY), in: table)
    }

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

        let connections = model.registry.openConnections.sorted { $0.connectionTitle < $1.connectionTitle }
        if !connections.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Connections"))
            for connection in connections {
                add(connection.connectionTitle) { [weak self] in self?.navigate(to: connection.homeDirectory) }
            }
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

        let anchor = NSPoint(x: 4, y: pathBar.bounds.height)
        menu.popUp(positioning: menu.items.first, at: anchor, in: pathBar)
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

    // MARK: Command line

    /// Left or Right: the command line for this pane's folder.
    func showCommandLine() {
        commandBar.show(folder: commandLineFolderName)
    }

    func hideCommandLine() {
        commandBar.isHidden = true
        view.window?.makeFirstResponder(table)
    }

    /// The folder's name as the command line shows and speaks it; the top of a disk by its volume name.
    var commandLineFolderName: String {
        let directory = model.directory
        if let listing = Listings.info(directory.location) { return listing.title }
        guard directory.isRoot else { return directory.name }
        if directory.location == .local,
           let name = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
            return name
        }
        return directory.path
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
            let changedDirectory = shownDirectory != model.directory
            if changedDirectory {
                // The old folder's answers do not apply; keep the columns until the new ones
                // arrive, so the table does not jump in and out of the Git column. Before the
                // rows are drawn: search results show names relative to the folder searched.
                annotations = annotations.mapValues { _ in ColumnAnnotation() }
                columnContext = makeColumnContext()
            }
            table.reloadData()
            let target = cursor.flatMap { path in model.rows.firstIndex { $0.path == path } } ?? 0
            moveCursor(to: target)
            updateHeader()
            updateStatus()
            if changedDirectory {
                shownDirectory = model.directory
                sizeTask?.cancel()
                cancelSpaceSizes()
                rememberVolumeDirectory()
                tabsDirectoryChanged()
                delegate?.paneDidChangeDirectory(self)
            }
            if filterBar.isEditing {
                filterBar.matchCount = model.rows.count
            }
            refreshAnnotations()
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
            report(Self.describe(error))
        }
    }

    /// Shows an error in the status line, beeps and announces it.
    func report(_ message: String) {
        NSSound.beep()
        statusLabel.stringValue = message
        statusLabel.textColor = Theme.errorText
        delegate?.pane(self, announce: message)
    }

    private static func fallbackDirectory(for directory: VFSPath) -> VFSPath? {
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        // Inside an archive: start from the folder holding the outermost archive.
        let outermost = directory.outermostContainer
        var candidate = outermost == directory ? directory.parent : outermost.parent
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
        pathBar.isActive = isActive
        pathBar.show(model.directory)
    }

    /// Cmd+L: keyboard focus on the path bar's last part (the current folder).
    func focusPathBar() {
        pathBar.focusLast()
    }

    /// A path bar part was chosen: go there, with the cursor on the folder (or archive) that leads
    /// back towards where the pane was, like Backspace. Focus returns to the list.
    private func goToPathSegment(_ segment: PathBar.Segment, next: PathBar.Segment?) {
        var cursor: VFSPath?
        if let next {
            cursor = next.path.location == segment.path.location ? next.path : next.path.location.container
        } else {
            cursor = cursorPath
        }
        navigate(to: segment.path, cursor: cursor)
        view.window?.makeFirstResponder(table)
    }

    /// The status line text; also what Option+I reads.
    var statusText: String {
        if model.isLoading { return "Loading..." }
        let size = settings.formatters.size
        var files = 0, dirs = 0, selFiles = 0, selDirs = 0
        var totalBytes: Int64 = 0, selBytes: Int64 = 0
        for item in model.rows {
            let isSel = model.selected.contains(item.path)
            if item.isDirectoryLike {
                dirs += 1
                // Folder sizes count once calculated (Cmd+Shift+S), as in Total Commander.
                totalBytes += item.size ?? 0
                if isSel { selDirs += 1; selBytes += item.size ?? 0 }
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
        delegate?.pane(self, announce: key == .unsorted ? "Unsorted"
                       : "Sorted by \(key.spokenName), \(d.ascending ? "ascending" : "descending")")
    }

    func tableViewColumnDidResize(_ notification: Notification) { saveColumnLayout() }
    func tableViewColumnDidMove(_ notification: Notification) { saveColumnLayout() }

    func tableViewSelectionDidChange(_ notification: Notification) { delegate?.paneCursorDidChange(self) }
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

    /// A cell's spoken text: the column's spoken text when given, otherwise its visible text
    /// ("" leaves the cell out, e.g. a folder's empty extension). The name adds ", selected".
    func paneTable(_ table: PaneTableView, spokenTextForRow row: Int, column: Int) -> String {
        guard row < model.rows.count, column < table.tableColumns.count,
              let def = ColumnCatalog.definition(ColumnID(rawValue: table.tableColumns[column].identifier.rawValue))
        else { return "" }
        let item = model.rows[row]
        let text = def.spoken(item, columnContext) ?? def.text(item, columnContext)
        if def.id == .name, model.selected.contains(item.path) { return "\(text), selected" }
        return text
    }

    func paneTableMenu(_ table: PaneTableView) -> NSMenu? {
        delegate?.paneContextMenu(self)
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
        case .unsorted: "listing order"
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
