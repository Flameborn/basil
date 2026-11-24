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
    /// The pane context menu (right click, VO+Shift+M, Shift+F10), like TC's file context menu.
    /// Commands that do not fit the items (`Command.isApplicable`) are left out when it opens.
    public private(set) var contextMenu: [MenuNode] = []
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

    /// Takes a command out of every menu and the context menu (a plugin turned off); submenus
    /// left empty are removed too.
    public func remove(_ id: CommandID) {
        func strip(_ nodes: [MenuNode]) -> [MenuNode] {
            nodes.compactMap { node in
                switch node {
                case .command(let c): return c == id ? nil : node
                case .submenu(let title, let children):
                    let kept = strip(children)
                    return kept.isEmpty && !children.isEmpty ? nil : .submenu(title, kept)
                case .separator: return node
                }
            }
        }
        for i in menus.indices { menus[i].items = strip(menus[i].items) }
        contextMenu = strip(contextMenu)
        onChange?()
    }

    /// Appends `items` to the pane context menu, or to a submenu of it.
    public func addToContextMenu(_ items: [MenuNode], submenu path: [String] = []) {
        contextMenu = Self.append(items, into: contextMenu, path: path[...])
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
