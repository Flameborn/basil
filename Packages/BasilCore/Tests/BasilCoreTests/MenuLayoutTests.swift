import Testing
@testable import BasilCore

@MainActor
struct MenuLayoutTests {
    @Test func addsToMenusAndNestedSubmenus() {
        let layout = MenuLayout()
        var changes = 0
        layout.onChange = { changes += 1 }
        layout.addMenu("Files", items: [.command("file.copy")])
        layout.add([.command("plugin.one")], to: "Files", submenu: ["Plugins", "Mine"])
        layout.add([.command("plugin.two")], to: "Files", submenu: ["Plugins", "Mine"])
        layout.add([.command("net.connect")], to: "Net")
        layout.addMenu("Files", items: [.separator])

        #expect(layout.menus.map(\.title) == ["Files", "Net"])
        #expect(layout.menus[0].items == [
            .command("file.copy"),
            .submenu("Plugins", [.submenu("Mine", [.command("plugin.one"), .command("plugin.two")])]),
            .separator,
        ])
        #expect(layout.menus[1].items == [.command("net.connect")])
        #expect(changes == 5)
    }

    @Test func contextMenuItemsAndApplicability() {
        let layout = MenuLayout()
        layout.addToContextMenu([.command("file.copy"), .separator])
        layout.addToContextMenu([.command("plugin.share")], submenu: ["Share"])
        #expect(layout.contextMenu == [.command("file.copy"), .separator, .submenu("Share", [.command("plugin.share")])])

        final class Context: WorkspaceContext {
            var activeDirectory: VFSPath? { nil }
            var otherDirectory: VFSPath? { nil }
            var cursorItem: FileItem? { nil }
            var targetItems: [FileItem] { [] }
            func navigate(to directory: VFSPath) {}
            func announce(_ message: String) {}
        }
        let ctx = Context()
        let registry = CommandRegistry()
        registry.register(.init(id: "a", title: "A") { _ in })
        registry.register(.init(id: "b", title: "B", isApplicable: { _ in false }) { _ in })
        #expect(registry.isApplicable("a", in: ctx))
        #expect(!registry.isApplicable("b", in: ctx))
        registry.setApplicability(of: "a") { $0.cursorItem != nil }
        registry.setApplicability(of: "b") { _ in true }
        #expect(!registry.isApplicable("a", in: ctx))
        #expect(registry.isApplicable("b", in: ctx))
    }

    @Test func primaryChordPrefersTheFirstDefaultKeyStillBound() {
        let registry = CommandRegistry()
        registry.register(.init(id: "a", title: "A", defaultKeys: [KeyChord(.function(8)), KeyChord(.forwardDelete)]) { _ in })
        #expect(registry.primaryChord(for: "a") == KeyChord(.function(8)))
        registry.bind(KeyChord(.function(8)), to: nil)
        #expect(registry.primaryChord(for: "a") == KeyChord(.forwardDelete))
    }
}

struct UnsortedOrderTests {
    @Test func keepsTheListingOrderWithFoldersFirst() {
        let items = [
            FileItem(path: .local("/t/b.txt"), kind: .file),
            FileItem(path: .local("/t/Z"), kind: .directory),
            FileItem(path: .local("/t/a.txt"), kind: .file),
            FileItem(path: .local("/t/A"), kind: .directory),
        ]
        let order = ListSortOrder(key: .unsorted)
        let sorted = ItemSorter.sorted(items, by: order)
        #expect(sorted.map(\.name) == ["Z", "A", "b.txt", "a.txt"])
        #expect(ItemSorter.insertionIndex(of: FileItem(path: .local("/t/M"), kind: .directory), in: sorted, by: order) == 2)
        #expect(ItemSorter.insertionIndex(of: FileItem(path: .local("/t/c"), kind: .file), in: sorted, by: order) == 4)
    }
}
