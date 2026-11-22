/// The command menus of the menu bar (Total Commander style: Files, Mark, Commands, Net, Show, Tabs),
/// described by command ID so built-in features and plugins add items the same way. The UI turns
/// this into real menus and skips commands that are not registered.
public indirect enum MenuNode: Hashable, Sendable {
    case command(CommandID)
    case submenu(String, [MenuNode])
    case separator
}

@MainActor
public final class MenuLayout {
    public struct Menu: Sendable {
        public let title: String
        public var items: [MenuNode]
        /// Shown, disabled, while the menu has nothing else to show ("No connections yet").
        public var placeholder: String?
    }

    public private(set) var menus: [Menu] = []
    /// Called after every change, so the menu bar can be rebuilt.
    public var onChange: (() -> Void)?

    public init() {}

    /// Adds a top-level menu, or appends to the existing one with the same title.
    public func addMenu(_ title: String, items: [MenuNode] = [], placeholder: String? = nil) {
        if let index = menus.firstIndex(where: { $0.title == title }) {
            menus[index].items += items
            if placeholder != nil { menus[index].placeholder = placeholder }
        } else {
            menus.append(Menu(title: title, items: items, placeholder: placeholder))
        }
        onChange?()
    }

    /// Appends `items` to a top-level menu, or to a submenu inside it (`path` is the submenu titles).
    /// Missing menus and submenus are created.
    public func add(_ items: [MenuNode], to menu: String, submenu path: [String] = []) {
        if !menus.contains(where: { $0.title == menu }) { menus.append(Menu(title: menu, items: [])) }
        let index = menus.firstIndex { $0.title == menu }!
        menus[index].items = Self.append(items, into: menus[index].items, path: path[...])
        onChange?()
    }

    private static func append(_ items: [MenuNode], into nodes: [MenuNode], path: ArraySlice<String>) -> [MenuNode] {
        guard let title = path.first else { return nodes + items }
        var nodes = nodes
        for (i, node) in nodes.enumerated() {
            if case .submenu(let t, let children) = node, t == title {
                nodes[i] = .submenu(t, append(items, into: children, path: path.dropFirst()))
                return nodes
            }
        }
        nodes.append(.submenu(title, append(items, into: [], path: path.dropFirst())))
        return nodes
    }
}
