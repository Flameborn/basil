import AppKit
import BasilCore
import BasilOperations
import BasilSearch
import BasilVFS

/// Find Files (Option+F7), like Total Commander's Alt+F7: names, text inside files, size, date,
/// with a choice of search engine. Results are listed as they are found; Return on one goes to it
/// in the active pane, Show in Pane lists them all there (TC's "Feed to listbox"). The window keeps
/// its last search and results until a new search starts.
@MainActor
final class FindFilesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: MainWindowController?
    private let engines: SearchEngines
    private let defaults: UserDefaults
    private let settings: SettingsStore

    /// The folder "Search in" was filled with, and that text (unchanged text means this folder,
    /// also on a server or in an archive).
    private var suggestedFolder: VFSPath
    private var suggestedText = ""
    /// Where the shown results were searched.
    private var searchedFolder: VFSPath?
    private(set) var results: [FileItem] = []
    private var skipped = 0
    private var searchTask: Task<Void, Never>?
    private var reloadScheduled = false
    private var currentFolder: VFSPath?
    private var generation = 0
    var isSearching: Bool { searchTask != nil }

    private let nameField = NSComboBox()
    private let nameRegex = NSButton(checkboxWithTitle: "Name is a regular expression", target: nil, action: nil)
    private let folderField = NSTextField()
    private let subfolders = NSButton(checkboxWithTitle: "Search subfolders", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Include hidden items", target: nil, action: nil)
    private let archives = NSButton(checkboxWithTitle: "Search inside archives", target: nil, action: nil)
    private let kindPopup = NSPopUpButton()
    private let textField = NSComboBox()
    private let textCase = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let textRegex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let textWords = NSButton(checkboxWithTitle: "Whole words only", target: nil, action: nil)
    private let textNot = NSButton(checkboxWithTitle: "Files not containing the text", target: nil, action: nil)
    private let encodingPopup = NSPopUpButton()
    private let largerField = NSTextField()
    private let smallerField = NSTextField()
    private let datePopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    fileprivate let resultsTable = CompareTableView()
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var goButton: NSButton!
    private var feedButton: NSButton!

    /// "Modified" choices: title and how far back (nil: any time).
    private static let ages: [(String, TimeInterval?)] = [
        ("Any time", nil), ("In the last hour", 3600), ("In the last day", 86_400), ("In the last week", 7 * 86_400),
        ("In the last month", 30 * 86_400), ("In the last year", 365 * 86_400),
    ]
    private static let historyLimit = 20

    init(controller: MainWindowController, engines: SearchEngines, defaults: UserDefaults, folder: VFSPath) {
        self.controller = controller
        self.engines = engines
        self.defaults = defaults
        settings = controller.settings
        suggestedFolder = folder
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Find Files"
        window.basilAutosave("BasilFindFilesWindow")
        window.contentMinSize = NSSize(width: 760, height: 560)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        build()
        restoreOptions()
        if !window.setFrameUsingName("BasilFindFilesWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window with "Search in" set to `folder` (unless a search is running) and the
    /// focus in "Search for".
    func show(folder: VFSPath) {
        if !isSearching {
            suggestedFolder = folder
            suggestedText = Self.text(for: folder)
            folderField.stringValue = suggestedText
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stop(announcing: false)
    }

    private static func text(for folder: VFSPath) -> String {
        folder.location == .local ? folder.path : folder.description
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        func field(_ field: NSTextField, _ name: String, placeholder: String) {
            field.setAccessibilityLabel(name)
            field.placeholderString = placeholder
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        field(nameField, "Search for", placeholder: "*.mp3;*.flac, or part of a name; empty finds everything")
        nameField.completes = false
        nameField.setAccessibilityIdentifier("find.name")
        field(folderField, "Search in", placeholder: "Folder")
        folderField.setAccessibilityIdentifier("find.folder")
        field(textField, "Find text", placeholder: "Text inside files; empty searches names only")
        textField.completes = false
        textField.setAccessibilityIdentifier("find.text")
        field(largerField, "Larger than", placeholder: "for example 10 MB")
        field(smallerField, "Smaller than", placeholder: "for example 2 GB")
        for (popup, name) in [(kindPopup, "Find"), (encodingPopup, "Encoding"), (datePopup, "Modified"), (enginePopup, "Search with")] {
            popup.setAccessibilityLabel(name)
        }
        kindPopup.addItems(withTitles: SearchQuery.Kinds.allCases.map(\.title))
        encodingPopup.addItems(withTitles: TextQuery.Encodings.allCases.map(\.title))
        datePopup.addItems(withTitles: Self.ages.map(\.0))
        enginePopup.addItem(withTitle: "Automatic")
        enginePopup.addItems(withTitles: engines.all.map(\.title))
        enginePopup.setAccessibilityIdentifier("find.engine")
        subfolders.setAccessibilityIdentifier("find.subfolders")
        archives.setAccessibilityIdentifier("find.archives")

        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 12
            return stack
        }
        let grid = NSGridView(views: [
            [label("Search for:"), nameField],
            [NSGridCell.emptyContentView, row(nameRegex, kindPopup)],
            [label("Search in:"), folderField],
            [NSGridCell.emptyContentView, row(subfolders, hidden, archives)],
            [label("Find text:"), textField],
            [NSGridCell.emptyContentView, row(textCase, textRegex, textWords, textNot)],
            [label("Encoding:"), encodingPopup],
            [label("Larger than:"), row(largerField, label("Smaller than:"), smallerField)],
            [label("Modified:"), row(datePopup, label("Search with:"), enginePopup)],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for field in [largerField, smallerField] { field.widthAnchor.constraint(equalToConstant: 160).isActive = true }
        // Labels in the grid are read by VoiceOver on their own; the fields carry the same names.
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true

        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        status.setAccessibilityLabel("Status")
        status.setAccessibilityIdentifier("find.status")
        status.stringValue = "Type what to look for and press Return."

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Results"))
        column.title = "Results"
        column.resizingMask = .autoresizingMask
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        resultsTable.style = .plain
        resultsTable.rowHeight = Theme.rowHeight + 2
        resultsTable.intercellSpacing = NSSize(width: 0, height: 0)
        resultsTable.setAccessibilityLabel("Results")
        resultsTable.setAccessibilityIdentifier("find.results")
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.doubleAction = #selector(goToFile)
        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        startButton = NSButton(title: "Start Search", target: self, action: #selector(startSearch))
        startButton.setAccessibilityHelp("Return in the search fields")
        stopButton = NSButton(title: "Stop Search", target: self, action: #selector(stopSearch))
        stopButton.setAccessibilityHelp("Escape while searching")
        stopButton.isEnabled = false
        goButton = NSButton(title: "Go to File", target: self, action: #selector(goToFile))
        goButton.setAccessibilityHelp("Return in the results")
        feedButton = NSButton(title: "Show in Pane", target: self, action: #selector(showInPane))
        feedButton.setAccessibilityHelp("Lists the results in the active pane, where file commands work on them")
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.setAccessibilityHelp("Escape")
        let buttons = NSStackView(views: [startButton, stopButton, NSView(), goButton, feedButton, close])
        buttons.orientation = .horizontal
        updateButtons()

        let stack = NSStackView(views: [grid, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func updateButtons() {
        let searching = isSearching
        startButton.isEnabled = !searching
        stopButton.isEnabled = searching
        goButton.isEnabled = !results.isEmpty
        feedButton.isEnabled = !results.isEmpty && !searching
    }

    // MARK: Options

    private enum Key {
        static let query = "find.lastQuery"
        static let engine = "find.engine"
        static let age = "find.modified"
        static let larger = "find.larger"
        static let smaller = "find.smaller"
        static let names = "find.nameHistory"
        static let texts = "find.textHistory"
    }

    private func restoreOptions() {
        let saved = defaults.data(forKey: Key.query).flatMap { try? JSONDecoder().decode(SearchQuery.self, from: $0) } ?? SearchQuery()
        nameField.addItems(withObjectValues: defaults.stringArray(forKey: Key.names) ?? [])
        textField.addItems(withObjectValues: defaults.stringArray(forKey: Key.texts) ?? [])
        nameField.stringValue = saved.name
        nameRegex.state = saved.nameIsRegex ? .on : .off
        subfolders.state = saved.subfolders ? .on : .off
        hidden.state = saved.includeHidden ? .on : .off
        archives.state = saved.searchArchives ? .on : .off
        kindPopup.selectItem(at: SearchQuery.Kinds.allCases.firstIndex(of: saved.kinds) ?? 0)
        let text = saved.text ?? TextQuery(text: "")
        textField.stringValue = text.text
        textCase.state = text.caseSensitive ? .on : .off
        textRegex.state = text.regex ? .on : .off
        textWords.state = text.wholeWords ? .on : .off
        textNot.state = text.notContaining ? .on : .off
        encodingPopup.selectItem(at: TextQuery.Encodings.allCases.firstIndex(of: text.encodings) ?? 0)
        largerField.stringValue = defaults.string(forKey: Key.larger) ?? ""
        smallerField.stringValue = defaults.string(forKey: Key.smaller) ?? ""
        datePopup.selectItem(at: min(max(defaults.integer(forKey: Key.age), 0), Self.ages.count - 1))
        let engineID = defaults.string(forKey: Key.engine) ?? SearchEngines.automaticID
        enginePopup.selectItem(at: (engines.all.firstIndex { $0.id == engineID }).map { $0 + 1 } ?? 0)
    }

    private var chosenEngineID: String {
        let index = enginePopup.indexOfSelectedItem
        return index <= 0 ? SearchEngines.automaticID : engines.all[safe: index - 1]?.id ?? SearchEngines.automaticID
    }

    /// The query from the fields, or a reason it cannot run.
    private func makeQuery() -> Result<SearchQuery, SearchFormError> {
        let base = settings.settings.size.base
        func size(_ field: NSTextField, _ name: String) -> Result<Int64?, SearchFormError> {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .success(nil) }
            if let bytes = Int64(text) { return .success(bytes) }
            switch SplitSizes.parse(text, decimal: base == 1000) {
            case .success(let bytes): return .success(bytes)
            case .failure: return .failure(SearchFormError("\(name) is not a size Basil understands. Try for example 10 MB."))
            }
        }
        var query = SearchQuery(name: nameField.stringValue, nameIsRegex: nameRegex.state == .on,
                                subfolders: subfolders.state == .on,
                                kinds: SearchQuery.Kinds.allCases[safe: kindPopup.indexOfSelectedItem] ?? .filesAndFolders,
                                includeHidden: hidden.state == .on)
        query.searchArchives = archives.state == .on
        do {
            query.minimumSize = try size(largerField, "Larger than").get()
            query.maximumSize = try size(smallerField, "Smaller than").get()
        } catch {
            return .failure(error)
        }
        if let age = Self.ages[safe: datePopup.indexOfSelectedItem]?.1 { query.modifiedAfter = Date().addingTimeInterval(-age) }
        query.text = TextQuery(text: textField.stringValue, caseSensitive: textCase.state == .on, regex: textRegex.state == .on,
                               wholeWords: textWords.state == .on,
                               encodings: TextQuery.Encodings.allCases[safe: encodingPopup.indexOfSelectedItem] ?? .all,
                               notContaining: textNot.state == .on)
        do { _ = try query.nameFilter() } catch {
            return .failure(SearchFormError("\"\(query.name)\" is not a valid regular expression."))
        }
        if query.searchesText, let text = query.text {
            do { _ = try TextMatcher(text) } catch { return .failure(SearchFormError(error.localizedDescription + ".")) }
        }
        return .success(query)
    }

    private func saveOptions(_ query: SearchQuery) {
        var stored = query
        stored.modifiedAfter = nil // The age pop-up is saved instead.
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Key.query) }
        defaults.set(chosenEngineID, forKey: Key.engine)
        defaults.set(datePopup.indexOfSelectedItem, forKey: Key.age)
        defaults.set(largerField.stringValue, forKey: Key.larger)
        defaults.set(smallerField.stringValue, forKey: Key.smaller)
        remember(query.name, in: nameField, key: Key.names)
        remember(query.text?.text ?? "", in: textField, key: Key.texts)
    }

    private func remember(_ value: String, in box: NSComboBox, key: String) {
        guard !value.isEmpty else { return }
        var history = defaults.stringArray(forKey: key) ?? []
        history.removeAll { $0 == value }
        history.insert(value, at: 0)
        history = Array(history.prefix(Self.historyLimit))
        defaults.set(history, forKey: key)
        box.removeAllItems()
        box.addItems(withObjectValues: history)
        box.stringValue = value
    }

    // MARK: Searching

    @objc private func startSearch() {
        guard !isSearching, let controller else { return }
        let query: SearchQuery
        switch makeQuery() {
        case .success(let made): query = made
        case .failure(let error): return say(error.message)
        }
        let text = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        let folder = text == suggestedText ? suggestedFolder
            : controller.resolve(text.isEmpty ? suggestedText : text, relativeTo: controller.activePane.model.directory)
        guard let folder else { return say("Type the folder to search in.") }
        guard let engine = engines.resolve(chosenEngineID, for: query, in: folder, registry: controller.providers) else {
            return say("No search engine can search \(folder.displayName).")
        }
        if let refusal = engine.refusal(for: query, in: folder, registry: controller.providers) { return say(refusal + ".") }
        saveOptions(query)

        generation += 1
        let token = generation
        results = []
        skipped = 0
        searchedFolder = folder
        currentFolder = folder
        resultsTable.reloadData()
        let registry = controller.providers
        let folderName = folder.isRoot ? Self.text(for: folder) : folder.displayName
        status.stringValue = "Searching \(folderName) with \(engine.title)"
        let notice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, token == self.generation, self.isSearching else { return }
            self.controller?.announce("Searching")
        }
        searchTask = Task { [weak self] in
            var failure: Error?
            var cancelled = false
            do {
                for try await event in engine.search(query, in: folder, registry: registry) {
                    guard let self, token == self.generation else { return }
                    switch event {
                    case .found(let items):
                        self.results += items
                    case .searching(let current):
                        self.currentFolder = current
                    case .skipped:
                        self.skipped += 1
                    }
                    self.scheduleRefresh()
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                failure = error
            }
            notice.cancel()
            guard let self, token == self.generation else { return }
            self.finish(cancelled: cancelled || Task.isCancelled, failure: failure, in: folderName, engine: engine.title)
        }
        updateButtons()
    }

    private func finish(cancelled: Bool, failure: Error?, in folderName: String, engine: String) {
        searchTask = nil
        resultsTable.reloadData()
        var text: String
        if let failure {
            text = "Could not search \(folderName): \(failure.localizedDescription)"
        } else if cancelled {
            text = "Stopped, \(found)"
        } else {
            text = results.isEmpty ? "Nothing found in \(folderName) with \(engine)" : "Found \(found) in \(folderName) with \(engine)"
        }
        if skipped > 0 { text += ", \(skipped) \(skipped == 1 ? "item" : "items") could not be read" }
        status.stringValue = text
        updateButtons()
        // Like TC, the list gets the focus once something was found, so Up and Down read the results.
        if !results.isEmpty {
            window?.makeFirstResponder(resultsTable)
            resultsTable.selectRowIndexes(IndexSet(integer: max(resultsTable.selectedRow, 0)), byExtendingSelection: false)
        }
        say(text, show: false)
    }

    private var found: String { FeedbackText.items(results.count) }

    /// Refreshes the list and the status at most four times a second while results arrive.
    private func scheduleRefresh() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.reloadScheduled = false
            guard self.isSearching else { return }
            let selected = self.resultsTable.selectedRow
            self.resultsTable.reloadData()
            if selected >= 0 { self.resultsTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
            let place = self.currentFolder.map { $0.isRoot ? Self.text(for: $0) : $0.displayName } ?? ""
            self.status.stringValue = "Searching \(place), \(self.found) so far"
            self.updateButtons()
        }
    }

    @objc private func stopSearch() { stop(announcing: true) }

    private func stop(announcing: Bool) {
        guard let task = searchTask else { return }
        task.cancel()
        guard !announcing else { return }
        // Closing the window: stop quietly.
        generation += 1
        searchTask = nil
        status.stringValue = "Stopped, \(found)"
        updateButtons()
    }

    private func say(_ message: String, show: Bool = true) {
        if show { status.stringValue = message }
        controller?.announce(message)
    }

    // MARK: Results

    private var selectedResult: FileItem? { results[safe: resultsTable.selectedRow] }

    /// The folder part of a result: the path below the folder searched, its name right inside it.
    private func folderText(of item: FileItem) -> String {
        guard let base = searchedFolder else { return "" }
        let context = ColumnDefinition.Context(formatters: settings.formatters,
                                               namesRelativeTo: base)
        let part = context.folderPart(of: item) ?? ""
        return part.isEmpty ? (base.isRoot ? Self.text(for: base) : base.displayName) : part
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = results[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: [nil, nil, 96, 150], flexibleFont: Theme.listFont)
        let formatters = settings.formatters
        let size = item.isDirectoryLike ? "dir" : item.size.map(formatters.size.string) ?? ""
        let date = formatters.date(item.modified)
        let folder = folderText(of: item)
        cell.show([item.name, folder, item.isDirectoryLike ? "<DIR>" : size, date],
                  spoken: [item.name, size, "in \(folder)", date].filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CompareRowBackground() }

    /// Return in the results: the active pane goes to the item's folder with the cursor on it.
    @objc private func goToFile() {
        guard let item = selectedResult, let controller, let folder = item.path.parent else { return }
        let pane = controller.activePane
        close()
        pane.navigate(to: folder, cursor: item.path)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(pane.tableView)
    }

    /// Lists the results in the active pane (TC's "Feed to listbox").
    @objc private func showInPane() {
        guard !isSearching, !results.isEmpty, let controller, let origin = searchedFolder else { return }
        let listing = SearchResultsProvider(items: results, origin: origin, title: "Search results", registry: controller.providers)
        controller.providers.register(listing: listing)
        let pane = controller.activePane
        let cursor = selectedResult?.path
        close()
        pane.navigate(to: listing.root, cursor: cursor)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(pane.tableView)
    }

    @objc private func closeWindow() { window?.close() }

    private func handle(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord(.escape):
            if isSearching { stopSearch() } else { closeWindow() }
        case KeyChord(.character("w"), .command): closeWindow()
        case KeyChord(.enter):
            if window?.firstResponder === resultsTable { goToFile() } else if isSearching { return false } else { startSearch() }
        default: return false
        }
        return true
    }
}

struct SearchFormError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension MainWindowController {
    /// Option+F7: Find Files, searching the active pane's folder.
    func findFiles() {
        let folder = Listings.info(activePane.model.directory.location)?.origin ?? activePane.model.directory
        if findWindow == nil {
            findWindow = FindFilesWindowController(controller: self, engines: searchEngines, defaults: defaults, folder: folder)
        }
        findWindow?.show(folder: folder)
    }
}

extension FindFilesWindowController {
    /// The archives the shown results are in (kept open while the window lists them).
    var locationsInUse: Set<ProviderLocation> { Set(results.map(\.path.location)) }
}
