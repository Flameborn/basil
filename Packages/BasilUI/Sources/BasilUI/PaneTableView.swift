import AppKit
import BasilCore

@MainActor
protocol PaneTableViewKeyDelegate: AnyObject {
    /// Return true if the chord ran a command.
    func paneTable(_ table: PaneTableView, perform chord: KeyChord) -> Bool
    func paneTable(_ table: PaneTableView, typeAhead text: String)
    func paneTableDidBecomeFirstResponder(_ table: PaneTableView)
}

/// The file list. Routes key presses to the command registry first, then to
/// type-ahead (plain printable characters jump to matching names), then to NSTableView.
final class PaneTableView: NSTableView {
    weak var keyDelegate: PaneTableViewKeyDelegate?
    /// Drawn with the full cursor colour only in the active pane.
    var isActivePane = false {
        didSet { if oldValue != isActivePane { needsDisplay = true; refreshVisibleRows() } }
    }

    private var typeAheadBuffer = ""
    private var lastTypeAhead = Date.distantPast

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyDelegate?.paneTableDidBecomeFirstResponder(self) }
        return ok
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

    func refreshVisibleRows() {
        let range = rows(in: visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) {
            (rowView(atRow: row, makeIfNecessary: false) as? PaneRowView)?.isActivePane = isActivePane
        }
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

    /// What VoiceOver reads (e.g. "song, selected"); nil means the visible text,
    /// "" means the cell is silent (e.g. a folder's "<DIR>" size, already said by the name cell).
    var spokenLabel: String?

    // The cell is the accessibility element; empty or silent cells are skipped.
    override func isAccessibilityElement() -> Bool {
        !(spokenLabel ?? textField?.stringValue ?? "").isEmpty
    }
    override func accessibilityLabel() -> String? { spokenLabel ?? textField?.stringValue }
    override func accessibilityValue() -> Any? { textField?.stringValue }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

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
            key = .character(chars)
        }
        self.init(key, mods)
    }
}
