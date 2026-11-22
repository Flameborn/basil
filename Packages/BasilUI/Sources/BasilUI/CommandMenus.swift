import AppKit
import BasilCore

/// The built-in command menus, Total Commander style adapted to the Mac and grouped into submenus
/// like TC's community Extended Menus. Commands that are not registered are left out, so the
/// layout can name commands that later features add.
@MainActor
enum BuiltinMenus {
    static func register(in layout: MenuLayout) {
        typealias N = MenuNode
        func c(_ ids: CommandID...) -> [N] { ids.map(N.command) }

        layout.addMenu("Files", items:
            c("pane.open", "file.view", "file.edit", "file.newFile", "file.info") + [.separator]
            + c("file.copy", "file.move", "file.rename", "file.multiRename", "file.mkdir") + [
                .submenu("Delete", c("file.delete", "file.deletePermanently")),
                .separator,
                .submenu("Archives", c("file.pack", "file.unpack", "file.testArchive", "pane.openArchive")),
                .submenu("Checksums", c("file.checksumCreate", "file.checksumVerify")),
                .separator,
            ] + c("file.calculateSize"))

        layout.addMenu("Mark", items:
            c("select.toggle", "select.group", "select.ungroup") + [.separator]
            + c("select.allFiles", "select.none", "select.invert", "select.restore") + [
                .submenu("Same Extension", c("select.sameExtension", "select.deselectSameExtension")),
            ])

        layout.addMenu("Commands", items: [
            .submenu("Go To", c("go.path") + [.separator]
                + c("go.home", "go.desktop", "go.documents", "go.downloads", "go.applications",
                    "go.utilities", "go.iCloud", "go.computer") + [.separator]
                + c("pane.parent", "cursor.first", "cursor.last")),
            .submenu("Locations", c("pane.locations", "pane.locationsLeft", "pane.locationsRight")),
            .separator,
        ] + c("pane.switch", "pane.quickFilter", "pane.reload", "tools.terminal", "queue.show"))

        layout.addMenu("Net", placeholder: "No connections yet")

        layout.addMenu("Show", items: [
            .submenu("View Mode", c("view.brief", "view.full") + [.separator]
                + (1...9).map { N.command(CommandID(rawValue: "view.custom\($0)")) }),
            .submenu("Sort By", c("sort.name", "sort.ext", "sort.date", "sort.size", "sort.unsorted")),
            .separator,
        ] + c("pane.toggleHidden", "pane.readStatus"))

        layout.addMenu("Tabs", items:
            c("tab.new", "tab.duplicate", "tab.close", "tab.closeOthers") + [.separator]
            + c("tab.next", "tab.previous") + [.separator]
            + c("tab.rename", "tab.lock"))
    }
}

/// Builds NSMenus from the command registry's `MenuLayout`. Every item runs its command through the
/// registry and shows the command's current key. The keys are shown only: the menus never take a
/// key themselves (`menuHasKeyEquivalent` says no), so keys keep going through the panes and the
/// registry exactly as before, and F5 or Return typed in a dialog never fires a menu item.
@MainActor
final class CommandMenuBuilder: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let commands: CommandRegistry
    private let perform: (CommandID) -> Void
    private let context: () -> (any WorkspaceContext)?

    init(commands: CommandRegistry, context: @escaping () -> (any WorkspaceContext)?,
         perform: @escaping (CommandID) -> Void) {
        self.commands = commands
        self.context = context
        self.perform = perform
    }

    /// One top-level menu-bar item per menu in the layout.
    func topLevelItems() -> [NSMenuItem] {
        commands.menus.menus.map { menu in
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            let submenu = LayoutMenu(title: menu.title, nodes: menu.items, placeholder: menu.placeholder)
            submenu.delegate = self
            rebuild(submenu)
            item.submenu = submenu
            return item
        }
    }

    /// Items are rebuilt each time a menu opens, so titles, keys, checkmarks and hidden items
    /// (custom view slots without a view) are current.
    private func rebuild(_ menu: LayoutMenu) {
        menu.removeAllItems()
        let ctx = context()
        var pendingSeparator = false
        for node in menu.nodes {
            switch node {
            case .separator:
                pendingSeparator = menu.numberOfItems > 0
            case .command(let id):
                guard let command = commands.command(id) else { continue }
                let title: String
                if let menuTitle = command.menuTitle {
                    guard let ctx, let t = menuTitle(ctx) else { continue }
                    title = t
                } else {
                    title = command.title
                }
                if pendingSeparator { menu.addItem(.separator()); pendingSeparator = false }
                let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.rawValue
                if let chord = commands.primaryChord(for: id), let key = chord.menuKeyEquivalent {
                    item.keyEquivalent = key.characters
                    item.keyEquivalentModifierMask = key.modifiers
                }
                if let isChecked = command.isChecked, let ctx { item.state = isChecked(ctx) ? .on : .off }
                menu.addItem(item)
            case .submenu(let title, let children):
                let submenu = LayoutMenu(title: title, nodes: children, placeholder: nil)
                submenu.delegate = self
                rebuild(submenu)
                guard submenu.numberOfItems > 0 else { continue }
                if pendingSeparator { menu.addItem(.separator()); pendingSeparator = false }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        if menu.numberOfItems == 0, let placeholder = menu.placeholder {
            let item = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        perform(CommandID(rawValue: raw))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let command = commands.command(CommandID(rawValue: raw)),
              let ctx = context() else { return false }
        return command.isEnabled(ctx)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let menu = menu as? LayoutMenu { rebuild(menu) }
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }
}

/// A menu that remembers the layout it was built from.
final class LayoutMenu: NSMenu {
    let nodes: [MenuNode]
    let placeholder: String?

    init(title: String, nodes: [MenuNode], placeholder: String?) {
        self.nodes = nodes
        self.placeholder = placeholder
        super.init(title: title)
    }

    required init(coder: NSCoder) { fatalError("not used") }
}

extension KeyChord {
    /// The menu item key equivalent that shows this chord, or nil when a menu cannot show it
    /// (keypad keys look the same as the main keys there, so they are left out).
    var menuKeyEquivalent: (characters: String, modifiers: NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        let chars: String
        switch key {
        case .character(let c): chars = c
        case .function(let n): chars = scalar(NSF1FunctionKey + n - 1)
        case .numpad: return nil
        case .tab: chars = "\t"
        case .enter: chars = "\r"
        case .backspace: chars = scalar(0x08)
        case .forwardDelete: chars = scalar(NSDeleteFunctionKey)
        case .space: chars = " "
        case .escape: chars = scalar(0x1B)
        case .up: chars = scalar(NSUpArrowFunctionKey)
        case .down: chars = scalar(NSDownArrowFunctionKey)
        case .left: chars = scalar(NSLeftArrowFunctionKey)
        case .right: chars = scalar(NSRightArrowFunctionKey)
        case .home: chars = scalar(NSHomeFunctionKey)
        case .end: chars = scalar(NSEndFunctionKey)
        case .pageUp: chars = scalar(NSPageUpFunctionKey)
        case .pageDown: chars = scalar(NSPageDownFunctionKey)
        }
        return (chars, flags)
    }
}

extension MainWindowController {
    /// Puts the command menus (Files, Mark, Commands, Net, Show, Tabs) into `mainMenu` after the item at
    /// `index` (the app menu and the Edit menu come first), and keeps them in step with the layout.
    public func installCommandMenus(in mainMenu: NSMenu, at index: Int) {
        BuiltinMenus.register(in: commands.menus)
        let builder = CommandMenuBuilder(commands: commands, context: { [weak self] in
            // While a sheet asks something, menu commands wait like the keys do.
            guard let self, window?.attachedSheet == nil else { return nil }
            return self
        }, perform: { [weak self] id in self?.performFromMenu(id) })
        menuBuilder = builder
        var installed: [NSMenuItem] = []
        func install() {
            installed.forEach(mainMenu.removeItem)
            installed = builder.topLevelItems()
            for (offset, item) in installed.enumerated() { mainMenu.insertItem(item, at: index + offset) }
        }
        install()
        commands.menus.onChange = install
    }

    func performFromMenu(_ id: CommandID) {
        guard commands.perform(id, in: self) else { return }
        quickLook.paneChanged(activePane)
    }
}
