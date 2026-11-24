import AppKit
import BasilCore
import BasilOperations
import BasilVFS

extension MainWindowController {
    /// The two files Compare by Content works on: two selected files in the active pane, or the
    /// selected (or cursor) file in each pane. Left is the left pane's file when they come from
    /// both panes.
    var comparePair: (left: FileItem, right: FileItem)? {
        func isFile(_ item: FileItem) -> Bool { if case .file = item.kind { return true } else { return false } }
        let selected = activePane.model.selectedItems.filter(isFile)
        if selected.count == 2 { return (selected[0], selected[1]) }
        func one(_ pane: PaneViewController) -> FileItem? {
            let marked = pane.model.selectedItems
            if marked.count == 1 { return isFile(marked[0]) ? marked[0] : nil }
            return pane.cursorItem.flatMap { isFile($0) ? $0 : nil }
        }
        guard selected.count < 2, let mine = one(activePane), let other = one(otherPane) else { return nil }
        return activeSide == .left ? (mine, other) : (other, mine)
    }

    func compareFiles() {
        guard let pair = comparePair else {
            announce("Select two files, or put the cursor on a file in each pane")
            return
        }
        let controller = CompareWindowController(left: pair.left, right: pair.right, registry: providers, settings: settings,
                                                 announce: { [weak self] in self?.announce($0) })
        controller.onIdentical = { [weak self] size in self?.showIdentical(pair.left, pair.right, size: size) }
        controller.show()
    }

    /// Like TC: files with the same content get a message, not the compare window.
    private func showIdentical(_ left: FileItem, _ right: FileItem, size: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "The files are identical"
        alert.informativeText = "\(left.name) and \(right.name) have the same content, \(size)."
        alert.addButton(withTitle: "OK")
        Task { _ = await present(alert, in: window) }
    }
}

/// Compare by Content, like Total Commander's, made for VoiceOver: a window with a summary
/// ("Identical", "3 differences"), Text and Binary modes, "Show only differences", and a table
/// whose rows each read as one sentence ("Changed, line 12: old, line 12: new"). F8 and
/// Shift+F8 (or the buttons) jump to the next and previous difference and speak it. Read-only.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int { case text, binary }

    private static var openWindows: Set<CompareWindowController> = []

    private let left: FileItem
    private let right: FileItem
    private let registry: ProviderRegistry
    private let settings: SettingsStore
    private let announce: (String) -> Void
    private var result: FileComparison?
    private var task: Task<Void, Never>?
    private var mode: Mode = .text
    private var onlyDifferences = false
    /// The rows shown, as indices into the text rows or binary rows; nil = all rows in order.
    private var visible: [Int64]?
    /// Visible row indices where a difference starts.
    private var differenceStarts: [Int] = []

    private let summary = NSTextField(wrappingLabelWithString: "Comparing")
    private let modePopUp = NSPopUpButton()
    private let onlyDifferencesBox = NSButton(checkboxWithTitle: "Show only differences", target: nil, action: nil)
    private let previousButton = NSButton(title: "Previous Difference", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next Difference", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let header = NSTextField(labelWithString: "")
    private let table = CompareTableView()
    /// Called instead of showing the window when both files have the same bytes, with the size.
    var onIdentical: ((String) -> Void)?

    init(left: FileItem, right: FileItem, registry: ProviderRegistry, settings: SettingsStore,
         announce: @escaping (String) -> Void) {
        self.left = left
        self.right = right
        self.registry = registry
        self.settings = settings
        self.announce = announce
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Compare \(left.name) and \(right.name)"
        window.basilAutosave("BasilCompareWindow")
        window.contentMinSize = NSSize(width: 700, height: 360)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        buildContent()
        if !window.setFrameUsingName("BasilCompareWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Compares first: the window opens once the files differ, or after a second while the
    /// comparison still runs (so it can be closed, which cancels it).
    func show() {
        Self.openWindows.insert(self)
        start()
    }

    private var isShown = false

    private func reveal() {
        guard !isShown else { return }
        isShown = true
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        Self.openWindows.remove(self)
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        summary.setAccessibilityLabel("Result")
        summary.setAccessibilityIdentifier("compare.summary")
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        modePopUp.addItems(withTitles: ["Text", "Binary"])
        modePopUp.autoenablesItems = false
        modePopUp.target = self
        modePopUp.action = #selector(modeChanged)
        modePopUp.setAccessibilityLabel("Mode")
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modeLabel.setAccessibilityElement(false)

        onlyDifferencesBox.target = self
        onlyDifferencesBox.action = #selector(onlyDifferencesChanged)
        previousButton.target = self
        previousButton.action = #selector(previousDifference)
        previousButton.setAccessibilityHelp("Shift+F8")
        nextButton.target = self
        nextButton.action = #selector(nextDifference)
        nextButton.setAccessibilityHelp("F8")
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.setAccessibilityHelp("Escape")

        let controls = NSStackView(views: [modeLabel, modePopUp, onlyDifferencesBox, previousButton, nextButton, NSView(), closeButton])
        controls.orientation = .horizontal
        controls.spacing = 10

        header.font = Theme.listBoldFont
        header.textColor = Theme.secondaryText
        header.setAccessibilityElement(false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Comparison"))
        column.title = "Comparison"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = Theme.rowHeight + 2
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Differences")
        table.setAccessibilityIdentifier("compare.table")
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let stack = NSStackView(views: [summary, controls, header, scroll])
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
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        setControlsEnabled(false)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for control in [modePopUp, onlyDifferencesBox, previousButton, nextButton] as [NSControl] { control.isEnabled = enabled }
    }

    // MARK: Comparing

    private func start() {
        let registry = registry, left = left.path, right = right.path
        let notice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, result == nil else { return }
            reveal()
            announce("Comparing")
        }
        task = Task { [weak self] in
            defer { notice.cancel() }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await FileComparison.compare(left, right, registry: registry)
                }.value
                self?.show(result)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                reveal()
                summary.stringValue = "Could not compare: \(PaneViewController.describe(error))"
                announce(summary.stringValue)
            }
        }
    }

    private func show(_ result: FileComparison) {
        self.result = result
        if result.identical, let onIdentical {
            if isShown { close() } else { Self.openWindows.remove(self) }
            onIdentical(settings.formatters.size.string(result.leftSize))
            return
        }
        reveal()
        let textAvailable = result.text != nil
        modePopUp.item(at: Mode.text.rawValue)?.isEnabled = textAvailable
        mode = textAvailable ? .text : .binary
        modePopUp.selectItem(at: mode.rawValue)
        setControlsEnabled(true)
        applyMode(announcing: true)
    }

    private var differenceCount: Int {
        guard let result else { return 0 }
        switch mode {
        case .text: return result.text?.differences.count ?? 0
        case .binary: return result.binary.differences.count
        }
    }

    private func summaryText() -> String {
        guard let result else { return "Comparing" }
        let size = settings.formatters.size
        if result.identical {
            return "Identical, \(size.string(result.leftSize))"
        }
        var parts: [String] = []
        if mode == .text, let text = result.text {
            if text.onlyLineEndingsDiffer {
                parts.append("The text is identical; only the line endings differ")
            } else {
                parts.append(count(text.differences.count, "difference"))
            }
        } else {
            let binary = result.binary
            parts.append(count(binary.differences.count, "difference"))
            if let first = result.firstDifference { parts.append("first at byte \(first.formatted())") }
            if binary.differingRowCount > Int64(binary.differingRows.count) {
                parts.append("the first \(binary.differingRows.count.formatted()) rows that differ are shown")
            }
        }
        if result.leftSize != result.rightSize {
            parts.append("sizes \(size.string(result.leftSize)) and \(size.string(result.rightSize))")
        }
        return parts.joined(separator: ", ")
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

    private func applyMode(announcing: Bool) {
        guard let result else { return }
        let binaryComplete = result.binary.isComplete
        // Big files keep only the rows that differ.
        if mode == .binary, !binaryComplete { onlyDifferences = true }
        onlyDifferencesBox.state = onlyDifferences ? .on : .off
        onlyDifferencesBox.isEnabled = mode == .text || binaryComplete

        switch mode {
        case .text:
            let text = result.text!
            header.stringValue = "Status        Left line, text        |        Right line, text"
            if onlyDifferences {
                let shown = text.rows.indices.filter { text.rows[$0].status != .same }
                visible = shown.map(Int64.init)
                let starts = Set(text.differences)
                differenceStarts = shown.indices.filter { starts.contains(shown[$0]) }
            } else {
                visible = nil
                differenceStarts = text.differences
            }
        case .binary:
            header.stringValue = "Status        Offset        Left bytes        |        Right bytes"
            let binary = result.binary
            if onlyDifferences {
                visible = binary.differingRows
                differenceStarts = binary.differences
            } else {
                visible = nil
                differenceStarts = binary.differences.map { Int(binary.differingRows[$0]) }
            }
        }
        summary.stringValue = summaryText()
        table.reloadData()
        let target = differenceStarts.first ?? 0
        if rowCount > 0 { select(target, speak: false) }
        if announcing { announce(summary.stringValue) }
    }

    private var rowCount: Int {
        guard let result else { return 0 }
        if let visible { return visible.count }
        switch mode {
        case .text: return result.text?.rows.count ?? 0
        case .binary: return Int(result.binary.rowCount)
        }
    }

    private func modelIndex(_ row: Int) -> Int64 { visible?[row] ?? Int64(row) }

    // MARK: Rows

    struct RowText {
        var status: CompareStatus
        var cells: [String]
        var spoken: String
    }

    private func rowText(_ row: Int) -> RowText? {
        guard let result, row >= 0, row < rowCount else { return nil }
        let index = modelIndex(row)
        switch mode {
        case .text:
            guard let text = result.text, text.rows.indices.contains(Int(index)) else { return nil }
            let r = text.rows[Int(index)]
            func spokenLine(_ number: Int?, _ line: String?) -> String? {
                guard let number else { return nil }
                let content = (line ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : line!
                return "line \(number): \(content)"
            }
            var spoken = r.status.rawValue
            switch r.status {
            case .same:
                let lines = r.leftLine == r.rightLine ? "line \(r.leftLine ?? 0)" : "line \(r.leftLine ?? 0), right line \(r.rightLine ?? 0)"
                let content = (r.leftText ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : r.leftText!
                spoken += ", \(lines): \(content)"
            default:
                spoken += ", " + [spokenLine(r.leftLine, r.leftText), spokenLine(r.rightLine, r.rightText)]
                    .compactMap { $0 }.joined(separator: ", ")
            }
            return RowText(status: r.status,
                           cells: [r.status.rawValue, r.leftLine.map(String.init) ?? "", r.leftText ?? "",
                                   r.rightLine.map(String.init) ?? "", r.rightText ?? ""],
                           spoken: spoken)
        case .binary:
            guard let r = result.binary.row(at: index) else { return nil }
            let hexLeft = Self.hex(r.left), hexRight = Self.hex(r.right)
            var spoken = "\(r.status.rawValue), offset \(r.offset.formatted())"
            if !r.left.isEmpty { spoken += ", left \(hexLeft)" }
            if !r.right.isEmpty { spoken += ", right \(hexRight)" }
            return RowText(status: r.status,
                           cells: [r.status.rawValue, String(format: "%08llX", r.offset), hexLeft, Self.ascii(r.left),
                                   hexRight, Self.ascii(r.right)],
                           spoken: spoken)
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

    static func ascii(_ data: Data) -> String {
        String(data.map { (0x20 ..< 0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let text = rowText(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier(mode == .text ? "textRow" : "binaryRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: mode == .text ? [90, 56, nil, 56, nil] : [90, 80, 360, 140, 360, 140])
        cell.show(text.cells, spoken: text.spoken)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompareRowBackground()
        view.status = rowText(row)?.status ?? .same
        return view
    }

    // MARK: Moving between differences

    private func select(_ row: Int, speak: Bool) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if speak, let text = rowText(row) { announce(text.spoken) }
    }

    @objc private func nextDifference() {
        guard result != nil else { return }
        let current = table.selectedRow
        if let next = differenceStarts.first(where: { $0 > current }) {
            select(next, speak: true)
        } else {
            announce(differenceStarts.isEmpty ? "No differences" : "No more differences")
        }
    }

    @objc private func previousDifference() {
        guard result != nil else { return }
        let current = table.selectedRow
        if let previous = differenceStarts.last(where: { $0 < current }) {
            select(previous, speak: true)
        } else {
            announce(differenceStarts.isEmpty ? "No differences" : "No earlier differences")
        }
    }

    @objc private func modeChanged() {
        guard let chosen = Mode(rawValue: modePopUp.indexOfSelectedItem), chosen != mode else { return }
        if chosen == .text, result?.text == nil {
            modePopUp.selectItem(at: mode.rawValue)
            return
        }
        mode = chosen
        applyMode(announcing: true)
    }

    @objc private func onlyDifferencesChanged() {
        onlyDifferences = onlyDifferencesBox.state == .on
        applyMode(announcing: false)
    }

    @objc private func closeWindow() { window?.close() }

    /// Keys anywhere in the window: F8 / Shift+F8 move between differences, Escape closes.
    private func handle(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord(.function(8)): nextDifference()
        case KeyChord(.function(8), .shift): previousDifference()
        case KeyChord(.escape): closeWindow()
        case KeyChord(.character("w"), .command): closeWindow()
        default: return false
        }
        return true
    }
}

/// Sends keys to the compare window's handler before the controls see them.
final class CompareNSWindow: NSWindow {
    var onKey: ((KeyChord) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let chord = KeyChord(event: event), onKey?(chord) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let chord = KeyChord(event: event), onKey?(chord) == true { return }
        super.sendEvent(event)
    }
}

/// The compare table: one column whose cells read as one sentence each.
final class CompareTableView: NSTableView {
    override var accessibilityFocusedUIElement: Any? {
        guard selectedRow >= 0, let cell = view(atColumn: 0, row: selectedRow, makeIfNecessary: false) else { return self }
        return cell
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        guard window?.firstResponder === self, selectedRow >= 0,
              let cell = view(atColumn: 0, row: selectedRow, makeIfNecessary: true) else { return }
        NSAccessibility.post(element: cell, notification: .focusedUIElementChanged)
    }
}

/// A row of the compare table: the parts side by side, read by VoiceOver as one sentence.
final class CompareRowCell: NSTableCellView {
    private var labels: [NSTextField] = []
    private var spoken = ""

    /// `flexibleFont`: the font of the parts without a fixed width (the list font by default).
    init(identifier: NSUserInterfaceItemIdentifier, widths: [CGFloat?], flexibleFont: NSFont? = nil) {
        super.init(frame: .zero)
        self.identifier = identifier
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        var flexible: [NSTextField] = []
        for width in widths {
            let label = NSTextField(labelWithString: "")
            label.font = width == nil ? (flexibleFont ?? Theme.listFont) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = Theme.text
            label.lineBreakMode = .byTruncatingTail
            // A label's accessibility element is its cell: hide both, the row reads as one sentence.
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let width {
                label.widthAnchor.constraint(equalToConstant: width).isActive = true
            } else {
                // Takes the room the fixed parts leave, so the parts after it line up in columns.
                label.setContentHuggingPriority(.init(1), for: .horizontal)
                flexible.append(label)
            }
            stack.addArrangedSubview(label)
            labels.append(label)
        }
        // Flexible parts (the two texts) share the rest equally.
        if flexible.count == 2 { flexible[0].widthAnchor.constraint(equalTo: flexible[1].widthAnchor).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Light text on the selection highlight, the theme's text elsewhere.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for label in labels { label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : Theme.text }
        }
    }

    func show(_ cells: [String], spoken: String) {
        for (label, text) in zip(labels, cells) { label.stringValue = text }
        self.spoken = spoken
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { spoken }
    override func accessibilityValue() -> Any? { spoken }
}

/// Row background by status (the Status part says the same in words).
final class CompareRowBackground: NSTableRowView {
    var status: CompareStatus = .same

    override func drawBackground(in dirtyRect: NSRect) {
        let color: NSColor? = switch status {
        case .same: nil
        case .changed: Theme.compareChanged
        case .onlyLeft: Theme.compareOnlyLeft
        case .onlyRight: Theme.compareOnlyRight
        }
        guard let color else { return super.drawBackground(in: dirtyRect) }
        color.setFill()
        bounds.fill()
    }
}
