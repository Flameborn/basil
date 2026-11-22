/// Commands are the single entry point for user actions: F-keys, menus, the
/// function-key bar, a future command palette and Lua plugins all invoke commands
/// by ID. Keybindings map chords to command IDs and can be remapped.

public struct CommandID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A key plus modifiers, independent of AppKit so plugins and settings can use it.
public struct KeyChord: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Key: Hashable, Sendable, Codable {
        /// A printable character, stored lowercased.
        case character(String)
        case function(Int)
        /// A key on the numeric keypad ("-", "+", "*", "/", "0"..."9", "."), kept apart from the main keys.
        case numpad(String)
        case tab, enter, backspace, forwardDelete, space, escape
        case up, down, left, right, home, end, pageUp, pageDown
    }

    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        if case .character(let c) = key {
            self.key = .character(c.lowercased())
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// Human-readable form in plain words, e.g. "Shift+F6", "Cmd+S". Used on screen and by VoiceOver,
    /// so it deliberately avoids symbol glyphs (they are read out awkwardly).
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "Ctrl+" }
        if modifiers.contains(.option) { s += "Option+" }
        if modifiers.contains(.shift) { s += "Shift+" }
        if modifiers.contains(.command) { s += "Cmd+" }
        switch key {
        case .character(let c): s += c.uppercased()
        case .function(let n): s += "F\(n)"
        case .numpad(let c): s += "Numpad " + (Self.numpadNames[c] ?? c)
        case .tab: s += "Tab"
        case .enter: s += "Return"
        case .backspace: s += "Backspace"
        case .forwardDelete: s += "Forward Delete"
        case .space: s += "Space"
        case .escape: s += "Esc"
        case .up: s += "Up"
        case .down: s += "Down"
        case .left: s += "Left"
        case .right: s += "Right"
        case .home: s += "Home"
        case .end: s += "End"
        case .pageUp: s += "Page Up"
        case .pageDown: s += "Page Down"
        }
        return s
    }

    private static let numpadNames = ["-": "Minus", "+": "Plus", "*": "Multiply", "/": "Divide",
                                      ".": "Decimal", "=": "Equals", ",": "Comma"]
}

/// What commands can see and do in the file manager window.
/// Implemented by the UI; used by built-in commands and plugins alike.
@MainActor
public protocol WorkspaceContext: AnyObject {
    var activeDirectory: VFSPath? { get }
    var otherDirectory: VFSPath? { get }
    /// The item under the cursor in the active pane (nil for "..").
    var cursorItem: FileItem? { get }
    /// Marked items in the active pane, or the cursor item when nothing is marked.
    var targetItems: [FileItem] { get }
    func navigate(to directory: VFSPath)
    /// Post a VoiceOver announcement and show it in the status area.
    func announce(_ message: String)
}

@MainActor
public final class CommandRegistry {
    public struct Command {
        public let id: CommandID
        public let title: String
        public let defaultKeys: [KeyChord]
        public let isEnabled: @MainActor (any WorkspaceContext) -> Bool
        public let run: @MainActor (any WorkspaceContext) -> Void
        /// The title menus show right now; nil hides the item (a custom view slot with no view).
        /// Without it menus use `title`.
        public let menuTitle: (@MainActor (any WorkspaceContext) -> String?)?
        /// Whether menus show the item checked (the current sort order or view).
        public let isChecked: (@MainActor (any WorkspaceContext) -> Bool)?

        public init(id: CommandID, title: String, defaultKeys: [KeyChord] = [],
                    isEnabled: @escaping @MainActor (any WorkspaceContext) -> Bool = { _ in true },
                    menuTitle: (@MainActor (any WorkspaceContext) -> String?)? = nil,
                    isChecked: (@MainActor (any WorkspaceContext) -> Bool)? = nil,
                    run: @escaping @MainActor (any WorkspaceContext) -> Void) {
            self.id = id
            self.title = title
            self.defaultKeys = defaultKeys
            self.isEnabled = isEnabled
            self.menuTitle = menuTitle
            self.isChecked = isChecked
            self.run = run
        }
    }

    private var commands: [CommandID: Command] = [:]
    private var registrationOrder: [CommandID] = []
    /// User overrides: chord -> command (or nil to unbind a default).
    private var overrides: [KeyChord: CommandID?] = [:]
    private var defaultKeymap: [KeyChord: CommandID] = [:]

    /// The menu bar's command menus. Built-in features and plugins add items here.
    public let menus = MenuLayout()

    public init() {}

    public func register(_ command: Command) {
        if commands[command.id] == nil { registrationOrder.append(command.id) }
        commands[command.id] = command
        for chord in command.defaultKeys { defaultKeymap[chord] = command.id }
    }

    public func command(_ id: CommandID) -> Command? { commands[id] }

    public var allCommands: [Command] { registrationOrder.compactMap { commands[$0] } }

    public func commandID(for chord: KeyChord) -> CommandID? {
        if let override = overrides[chord] { return override }
        return defaultKeymap[chord]
    }

    /// The chords currently bound to a command (defaults plus overrides).
    public func chords(for id: CommandID) -> [KeyChord] {
        var result = Set(defaultKeymap.filter { $0.value == id && overrides[$0.key] == nil }.map(\.key))
        for (chord, target) in overrides where target == id { result.insert(chord) }
        return result.sorted { $0.description < $1.description }
    }

    /// The chord shown for a command (menus, function-key bar): its first default key that is still
    /// bound to it, otherwise any chord bound to it.
    public func primaryChord(for id: CommandID) -> KeyChord? {
        let bound = chords(for: id)
        if let command = commands[id], let first = command.defaultKeys.first(where: bound.contains) { return first }
        return bound.first
    }

    public func bind(_ chord: KeyChord, to id: CommandID?) {
        overrides[chord] = .some(id)
    }

    /// Runs the command bound to `chord`. Returns false if nothing is bound.
    @discardableResult
    public func perform(_ chord: KeyChord, in context: any WorkspaceContext) -> Bool {
        guard let id = commandID(for: chord) else { return false }
        return perform(id, in: context)
    }

    @discardableResult
    public func perform(_ id: CommandID, in context: any WorkspaceContext) -> Bool {
        guard let command = commands[id], command.isEnabled(context) else { return false }
        command.run(context)
        return true
    }
}
