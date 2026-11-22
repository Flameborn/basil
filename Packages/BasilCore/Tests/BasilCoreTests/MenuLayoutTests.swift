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

    @Test func primaryChordPrefersTheFirstDefaultKeyStillBound() {
        let registry = CommandRegistry()
        registry.register(.init(id: "a", title: "A", defaultKeys: [KeyChord(.function(8)), KeyChord(.forwardDelete)]) { _ in })
        #expect(registry.primaryChord(for: "a") == KeyChord(.function(8)))
        registry.bind(KeyChord(.function(8)), to: nil)
        #expect(registry.primaryChord(for: "a") == KeyChord(.forwardDelete))
    }
}
