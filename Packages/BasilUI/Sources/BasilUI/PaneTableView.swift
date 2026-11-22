import AppKit
import BasilCore
import Quartz

@MainActor
protocol PaneTableViewKeyDelegate: AnyObject {
    /// Return true if the chord ran a command.
    func paneTable(_ table: PaneTableView, perform chord: KeyChord) -> Bool
    func paneTable(_ table: PaneTableView, typeAhead text: String)
    func paneTableDidBecomeFirstResponder(_ table: PaneTableView)
    /// The context menu for the cursor item.
    func paneTableMenu(_ table: PaneTableView) -> NSMenu?
    /// What VoiceOver reads for one cell (table column index); "" means the cell is not exposed.
    func paneTable(_ table: PaneTableView, spokenTextForRow row: Int, column: Int) -> String
}

/// The file list. Routes key presses to the command registry first, then to
/// type-ahead (plain printable characters jump to matching names), then to NSTableView.
final class PaneTableView: NSTableView {
    weak var keyDelegate: PaneTableViewKeyDelegate?
    /// F3: the Quick Look panel finds its controller through the responder chain, starting here.
    weak var quickLook: QuickLookController?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLook != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook?.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook?.end(panel) }
    /// Drawn with the full cursor colour only in the active pane.
    var isActivePane = false {
        didSet { if oldValue != isActivePane { needsDisplay = true; refreshVisibleRows() } }
    }

    private var typeAheadBuffer = ""
    private var lastTypeAhead = Date.distantPast

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            rowHasFocus = false
            keyDelegate?.paneTableDidBecomeFirstResponder(self)
        }
        return ok
    }

    /// Command-key chords bound in the CommandRegistry win over menu items, including the ones
    /// AppKit adds by itself (the standard Window menu's Minimize takes Cmd+M, which is Multi-Rename).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl chords too: AppKit takes Ctrl+Tab for moving between controls before keyDown sees it.
        if window?.firstResponder === self, event.type == .keyDown,
           !event.modifierFlags.isDisjoint(with: [.command, .control]),
           let chord = KeyChord(event: event), keyDelegate?.paneTable(self, perform: chord) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(event: event), keyDelegate?.paneTable(self, perform: chord) == true { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isDisjoint(with: [.command, .control, .option]),
           let chars = event.characters, let scalar = chars.unicodeScalars.first,
           chars.count == 1, !CharacterSet.controlCharacters.contains(scalar),
           scalar.value < 0xF700 || scalar.value > 0xF8FF, chars != " " {
            let now = Date()
            if now.timeIntervalSince(lastTypeAhead) > 1.0 { typeAheadBuffer = "" }
            lastTypeAhead = now
            typeAheadBuffer += chars
            keyDelegate?.paneTable(self, typeAhead: typeAheadBuffer)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Context menu

    /// Right click: the cursor moves to the clicked row first (unless it is one of the selected
    /// items), like TC.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return keyDelegate?.paneTableMenu(self)
    }

    /// Shift+F10 and VO+Shift+M: the menu opens at the cursor row.
    func showContextMenuAtCursor() {
        guard let menu = keyDelegate?.paneTableMenu(self) else { return }
        let point: NSPoint
        if selectedRow >= 0 {
            let rect = rect(ofRow: selectedRow)
            point = NSPoint(x: rect.minX + 24, y: rect.maxY)
        } else {
            point = NSPoint(x: visibleRect.minX + 24, y: visibleRect.minY + 24)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showContextMenuAtCursor()
        return true
    }

    // MARK: Accessibility
    //
    // NSTableView exposes one AXCell per column in every row. A cell with no text (a folder's empty
    // extension) makes VoiceOver say its position instead ("column 2, row 1"). Basil exposes its own
    // rows and cells instead, built from the model, and leaves out cells with nothing to say.
    // Only the visible rows and the cursor row are exposed, so 100k-row folders cost nothing here.

    private var rowElements: [Int: PaneRowElement] = [:]

    override func reloadData() {
        rowElements.removeAll()
        super.reloadData()
    }

    func rowElement(_ row: Int) -> PaneRowElement {
        if let element = rowElements[row] { return element }
        if rowElements.count > 500 { rowElements.removeAll() }
        let element = PaneRowElement(table: self, row: row)
        rowElements[row] = element
        return element
    }

    private var exposedRows: [PaneRowElement] {
        var indexes = IndexSet()
        let visible = rows(in: visibleRect)
        if visible.length > 0 { indexes.insert(integersIn: visible.location..<(visible.location + visible.length)) }
        if selectedRow >= 0 { indexes.insert(selectedRow) }
        return indexes.filter { $0 < numberOfRows }.map(rowElement)
    }

    // Keeps AppKit's other children (columns, header) so parents and children stay consistent.
    override func accessibilityChildren() -> [Any]? {
        // AppKit's own children are row proxies (dropped), NSTableColumn objects and the header view.
        let others = (super.accessibilityChildren() ?? []).filter { $0 is NSTableColumn || $0 is NSView }
        return exposedRows + others
    }
    @objc func accessibilityRows() -> [Any]? { exposedRows }
    @objc func accessibilityVisibleRows() -> [Any]? { exposedRows }
    @objc func accessibilitySelectedRows() -> [Any]? {
        selectedRow >= 0 && selectedRow < numberOfRows ? [rowElement(selectedRow)] : []
    }
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard row >= 0, row < numberOfRows else { return nil }
        return rowElement(row).cell(column: column)
    }

    // The cursor row is the focused element. Without this, VoiceOver put its cursor on the first
    // cell of the row when the list got focus by Tab, and then read only that column on Up/Down.
    // Focused on the row, it reads every cell of each row the cursor moves to.
    override var accessibilityFocusedUIElement: Any? {
        nonisolated(unsafe) var focused: Any? = self
        MainActor.assumeIsolated {
            if rowHasFocus, selectedRow >= 0, selectedRow < numberOfRows { focused = rowElement(selectedRow) }
        }
        return focused
    }

    /// False right after the list gets focus, so VoiceOver first reads the list ("Right pane, table,
    /// row 1 of 3, ..."); the first cursor move hands focus to the row.
    private var rowHasFocus = false
    private var selectionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard selectionObserver == nil else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.selectionDidChangeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.postCursorFocus() }
        }
    }

    private func postCursorFocus() {
        guard window?.firstResponder === self, selectedRow >= 0, selectedRow < numberOfRows else { return }
        rowHasFocus = true
        NSAccessibility.post(element: rowElement(selectedRow), notification: .focusedUIElementChanged)
    }

    func refreshVisibleRows() {
        let range = rows(in: visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) {
            (rowView(atRow: row, makeIfNecessary: false) as? PaneRowView)?.isActivePane = isActivePane
        }
    }
}

/// One row as VoiceOver sees it. Its cells' text comes from the pane model, not from the cell
/// views, so it is correct even for rows whose views are not loaded.
final class PaneRowElement: NSAccessibilityElement {
    fileprivate weak var table: PaneTableView?
    let row: Int
    private var cells: [Int: PaneCellElement] = [:]

    init(table: PaneTableView, row: Int) {
        self.table = table
        self.row = row
        super.init()
        setAccessibilityParent(table)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tableRow }
    override func accessibilityRoleDescription() -> String? { "" }
    override func accessibilityIndex() -> Int { row }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityChildren() -> [Any]? {
        guard let table else { return [] }
        return (0..<table.numberOfColumns).compactMap { cell(column: $0) }
    }

    /// The cell for a table column, or nil when it has nothing to say.
    func cell(column: Int) -> PaneCellElement? {
        guard let table, column >= 0, column < table.numberOfColumns,
              !PaneCellElement.text(table: table, row: row, column: column).isEmpty else { return nil }
        if let cell = cells[column] { return cell }
        let cell = PaneCellElement(rowElement: self, column: column)
        cells[column] = cell
        return cell
    }
    /// The whole row, read when the row has focus: "song, mp3, 1.5 MB, ...".
    override func accessibilityLabel() -> String? {
        guard let table else { return nil }
        return (0..<table.numberOfColumns)
            .map { PaneCellElement.text(table: table, row: row, column: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    override func isAccessibilityFocused() -> Bool {
        guard let table else { return false }
        return table.selectedRow == row && table.window?.firstResponder === table
    }
    override func isAccessibilitySelected() -> Bool { table?.selectedRow == row }
    override func setAccessibilitySelected(_ selected: Bool) {
        guard selected, let table, row < table.numberOfRows else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    override func accessibilityFrame() -> NSRect {
        guard let table, row < table.numberOfRows else { return .zero }
        return NSAccessibility.screenRect(fromView: table, rect: table.rect(ofRow: row))
    }
    /// VO+Shift+M on a row: the cursor goes to it, then its context menu opens.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let table, row < table.numberOfRows else { return false }
        if table.selectedRow != row { setAccessibilitySelected(true) }
        table.showContextMenuAtCursor()
        return true
    }
}

/// One non-empty cell of a PaneRowElement, e.g. "song, selected" or "1.5 MB".
final class PaneCellElement: NSAccessibilityElement {
    private weak var rowElement: PaneRowElement?
    let column: Int

    init(rowElement: PaneRowElement, column: Int) {
        self.rowElement = rowElement
        self.column = column
        super.init()
        setAccessibilityParent(rowElement)
    }

    static func text(table: PaneTableView, row: Int, column: Int) -> String {
        MainActor.assumeIsolated {
            guard row < table.numberOfRows else { return "" }
            return table.keyDelegate?.paneTable(table, spokenTextForRow: row, column: column) ?? ""
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityLabel() -> String? {
        guard let rowElement, let table = rowElement.table else { return nil }
        return Self.text(table: table, row: rowElement.row, column: column)
    }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: rowElement?.row ?? 0, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: column, length: 1) }
    override func accessibilityPerformShowMenu() -> Bool { rowElement?.accessibilityPerformShowMenu() ?? false }
    override func accessibilityFrame() -> NSRect {
        guard let rowElement, let table = rowElement.table, rowElement.row < table.numberOfRows,
              column < table.numberOfColumns else { return .zero }
        return NSAccessibility.screenRect(fromView: table, rect: table.frameOfCell(atColumn: column, row: rowElement.row))
    }
}

/// The visible label inside a cell. Hidden from accessibility: the cell view speaks for it.
final class CellTextField: NSTextField {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

/// Draws the Total Commander-style cursor bar: filled in the active pane, outlined in the inactive one.
final class PaneRowView: NSTableRowView {
    var isActivePane = true {
        didSet { if oldValue != isActivePane { needsDisplay = true; updateCellStyles() } }
    }
    var isAlternate = false

    // Rows are always operable; without this, assistive tech sees them as disabled ("dimmed").
    override func isAccessibilityEnabled() -> Bool { true }

    override var isEmphasized: Bool {
        get { isActivePane }
        set {}
    }

    override var isSelected: Bool {
        didSet { updateCellStyles() }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (isAlternate ? Theme.alternateRow : Theme.paneBackground).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isActivePane {
            Theme.cursorBackground.setFill()
            bounds.fill()
        } else {
            (isAlternate ? Theme.alternateRow : Theme.paneBackground).setFill()
            bounds.fill()
            Theme.inactiveCursor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func updateCellStyles() {
        for case let cell as PaneCellView in subviews {
            cell.showsCursor = isSelected && isActivePane
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? PaneCellView)?.showsCursor = isSelected && isActivePane
    }
}

/// One cell. Colours come from the theme and depend on selected/hidden/directory/cursor state.
final class PaneCellView: NSTableCellView {
    enum Style { case normal, directory, hidden }

    var style: Style = .normal { didSet { updateColors() } }
    var isSelectedItem = false { didSet { updateColors() } }
    var showsCursor = false { didSet { if oldValue != showsCursor { updateColors() } } }

    // VoiceOver reads whole rows (PaneRowElement); cells are not accessibility elements.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    private func updateColors() {
        guard let textField else { return }
        if showsCursor {
            textField.textColor = isSelectedItem ? Theme.cursorSelectedText : Theme.cursorText
        } else if isSelectedItem {
            textField.textColor = Theme.selectedText
        } else {
            textField.textColor = switch style {
            case .normal: Theme.text
            case .directory: Theme.directoryText
            case .hidden: Theme.hiddenText
            }
        }
    }
}

extension KeyChord {
    /// Translates an AppKit key event; nil for keys Basil doesn't bind (e.g. bare modifiers).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }

        guard let raw = event.charactersIgnoringModifiers, let rawScalar = raw.unicodeScalars.first else { return nil }
        // Function/navigation keys (private-use range) are taken as reported. For ordinary characters,
        // charactersIgnoringModifiers still applies Shift (Shift+. gives ">"), so bind on the unshifted key.
        let isSpecialKey = (0xF700...0xF8FF).contains(rawScalar.value)
        let chars = isSpecialKey ? raw : (event.characters(byApplyingModifiers: []) ?? raw)
        guard let scalar = chars.unicodeScalars.first else { return nil }
        let key: Key
        switch Int(scalar.value) {
        case NSF1FunctionKey...NSF35FunctionKey: key = .function(Int(scalar.value) - NSF1FunctionKey + 1)
        case NSUpArrowFunctionKey: key = .up
        case NSDownArrowFunctionKey: key = .down
        case NSLeftArrowFunctionKey: key = .left
        case NSRightArrowFunctionKey: key = .right
        case NSHomeFunctionKey: key = .home
        case NSEndFunctionKey: key = .end
        case NSPageUpFunctionKey: key = .pageUp
        case NSPageDownFunctionKey: key = .pageDown
        case NSDeleteFunctionKey: key = .forwardDelete
        case 0x09, 0x19: key = .tab // 0x19 = back-tab (Shift+Tab)
        case 0x0D, 0x03: key = .enter
        case 0x7F, 0x08: key = .backspace
        case 0x1B: key = .escape
        case 0x20: key = .space
        default:
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            // Arrow/function keys carry .function/.numericPad flags; they don't count as modifiers.
            // Keypad keys (Numpad Minus deselects all, as in Total Commander) bind apart from the main keys.
            key = event.modifierFlags.contains(.numericPad) ? .numpad(chars) : .character(chars)
        }
        self.init(key, mods)
    }
}
