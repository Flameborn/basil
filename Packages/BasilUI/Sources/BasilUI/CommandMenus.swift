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
            c("pane.open", "pane.showPackageContents", "file.view", "file.edit", "file.newFile", "file.info") + [.separator]
            + c("file.copy", "file.duplicate", "file.move", "file.rename", "file.multiRename", "file.mkdir") + [
                .submenu("Delete", c("file.delete", "file.deletePermanently") + [.separator] + c("file.appLeftovers")),
                .separator,
                .submenu("Archives", c("file.pack", "file.unpack", "file.testArchive", "pane.openArchive")),
                .submenu("Checksums", c("file.checksumCreate", "file.checksumVerify")),
                .submenu("Split", c("file.split", "file.combine")),
                .separator,
            ] + c("file.compare", "file.calculateSize"))

        layout.addMenu("Mark", items:
            c("select.toggle", "select.group", "select.ungroup") + [.separator]
            + c("select.allFiles", "select.none", "select.invert", "select.restore") + [
                .submenu("Same Extension", c("select.sameExtension", "select.deselectSameExtension")),
            ])

        layout.addMenu("Commands", items: [
            .submenu("Go To", c("go.path") + [.separator]
                + c("go.home", "go.desktop", "go.documents", "go.downloads", "go.applications",
                    "go.utilities", "go.iCloud", "go.computer") + [.separator]
                // No First Item / Last Item (Home, End): VoiceOver reads a menu item's title when
                // its key is pressed, which repeats what the cursor move already says.
                + c("pane.parent")),
            .submenu("Locations", c("pane.locations", "pane.locationsLeft", "pane.locationsRight")),
            .submenu("Git", c("git.commit", "git.branches", "git.log", "git.fileLog", "git.blame") + [.separator]
                + c("git.pull", "git.push", "git.fetch")),
            .separator,
        ] + c("pane.switch", "pane.focusPath", "pane.quickFilter", "pane.reload", "tools.terminal", "queue.show")
            + [.separator] + c("file.copyLink", "file.copyPath", "file.copyName", "pane.contextMenu"))

        layout.addMenu("Net", items: c("net.connect", "net.disconnect") + [.separator]
            + (1...20).map { N.command(CommandID(rawValue: "net.saved\($0)")) })

        layout.addMenu("Show", items: [
            .submenu("View Mode", c("view.brief", "view.full") + [.separator]
                + (1...9).map { N.command(CommandID(rawValue: "view.custom\($0)")) }),
            .submenu("Sort By", c("sort.name", "sort.ext", "sort.date", "sort.size", "sort.unsorted")),
            .separator,
        ] + c("pane.toggleHidden", "pane.readStatus"))

        layout.addMenu("Tabs", items:
            c("tab.new", "tab.duplicate", "tab.openCursorFolder", "tab.close", "tab.closeOthers") + [.separator]
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

    /// The pane context menu, built now for the current items.
    func contextMenu() -> NSMenu {
        let menu = LayoutMenu(title: "Context menu", nodes: commands.menus.contextMenu, placeholder: "No commands",
                              onlyApplicable: true)
        menu.delegate = self
        rebuild(menu)
        return menu
    }

    /// Items are rebuilt each time a menu opens, so titles, keys, checkmarks and hidden items
    /// (custom view slots without a view) are current.
    private func rebuild(_ menu: LayoutMenu) {
        menu.removeAllItems()
        let inMainMenu = isInMainMenu(menu)
        let ctx = context()
        var pendingSeparator = false
        for node in menu.nodes {
            switch node {
            case .separator:
                pendingSeparator = menu.numberOfItems > 0
            case .command(let id):
                guard let command = commands.command(id) else { continue }
                if menu.onlyApplicable, let ctx, !commands.isApplicable(id, in: ctx) { continue }
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
                let key = commands.primaryChord(for: id)?.menuKeyEquivalent
                if let isChecked = command.isChecked, let ctx { item.state = isChecked(ctx) ? .on : .off }
                menu.addItem(item)
                if let key {
                    if inMainMenu { borrowKey(key, for: item) }
                    item.keyEquivalentModifierMask = key.modifiers
                    item.keyEquivalent = key.characters
                }
            case .submenu(let title, let children):
                let submenu = LayoutMenu(title: title, nodes: children, placeholder: nil, onlyApplicable: menu.onlyApplicable)
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

    func menuDidClose(_ menu: NSMenu) {
        if menu.supermenu === NSApp.mainMenu { returnBorrowedKeys() }
    }

    /// A key taken from another menu-bar item (Edit > Copy, Window > Minimize) while a command
    /// menu is open, so the command's item can show it.
    private struct BorrowedKey {
        let owner: NSMenuItem
        let borrower: NSMenuItem
        let characters: String
    }
    private var borrowed: [BorrowedKey] = []

    /// AppKit clears the key of an item added to the menu bar when another item there already has
    /// that key (Edit > Copy has Cmd+C, so Copy Name showed none). The other item lends its key
    /// while this menu is open; the command menus never take keys themselves, so nothing changes
    /// for typing, and the key goes back when the menu closes (text fields need Edit > Copy).
    private func borrowKey(_ key: (characters: String, modifiers: NSEvent.ModifierFlags), for item: NSMenuItem) {
        guard let main = NSApp.mainMenu, let owner = itemWithKey(key, in: main) else { return }
        borrowed.append(BorrowedKey(owner: owner, borrower: item, characters: owner.keyEquivalent))
        owner.keyEquivalent = ""
        if !owner.keyEquivalent.isEmpty {
            // Items AppKit ties to a system shortcut (Window > Minimize) keep their key the first
            // time; setting another key first unties it.
            owner.keyEquivalent = " "
            owner.keyEquivalent = ""
        }
    }

    private func returnBorrowedKeys() {
        for entry in borrowed.reversed() {
            entry.borrower.keyEquivalent = ""
            entry.owner.keyEquivalent = entry.characters
        }
        borrowed.removeAll()
    }

    /// An item outside the command menus with this key.
    private func itemWithKey(_ key: (characters: String, modifiers: NSEvent.ModifierFlags), in menu: NSMenu) -> NSMenuItem? {
        if menu is LayoutMenu { return nil }
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = itemWithKey(key, in: submenu) { return found }
            } else if !item.keyEquivalent.isEmpty {
                var modifiers = item.keyEquivalentModifierMask.intersection(mask)
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                if item.keyEquivalent.lowercased() == key.characters.lowercased(),
                   modifiers == key.modifiers.intersection(mask) { return item }
            }
        }
        return nil
    }

    private func isInMainMenu(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let m = current {
            if m === NSApp.mainMenu { return true }
            current = m.supermenu
        }
        return false
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
    /// The context menu: commands that do not fit the current items are left out.
    let onlyApplicable: Bool

    init(title: String, nodes: [MenuNode], placeholder: String?, onlyApplicable: Bool = false) {
        self.nodes = nodes
        self.placeholder = placeholder
        self.onlyApplicable = onlyApplicable
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
    /// The Edit menu then moves after the first command menu, in the Mac order File, Edit, ...
    public func installCommandMenus(in mainMenu: NSMenu, at index: Int) {
        BuiltinMenus.register(in: commands.menus)
        ContextMenuCommands.registerLayout(in: commands.menus)
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
            if let files = installed.first, let edit = mainMenu.items.first(where: { $0.submenu?.title == "Edit" }) {
                mainMenu.removeItem(edit)
                mainMenu.insertItem(edit, at: mainMenu.index(of: files) + 1)
            }
        }
        install()
        commands.menus.onChange = install
    }

    public func performFromMenu(_ id: CommandID) {
        guard commands.perform(id, in: self) else { return }
        quickLook.paneChanged(activePane)
    }
}
