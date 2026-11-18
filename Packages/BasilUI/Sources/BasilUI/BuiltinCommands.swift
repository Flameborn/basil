import BasilCore

/// Built-in pane and navigation commands with their default (Total Commander, Mac-adapted) keys.
/// File operations (F3-F8) are registered but disabled until their milestones implement them.
@MainActor
enum BuiltinCommands {
    static let functionBarIDs: [CommandID] = [
        "file.view", "file.edit", "file.copy", "file.move", "file.mkdir", "file.delete",
    ]

    static func register(in registry: CommandRegistry, window: MainWindowController) {
        typealias C = CommandRegistry.Command
        typealias K = KeyChord
        weak let w = window
        func pane() -> PaneViewController? { w?.activePane }

        let commands: [C] = [
            C(id: "pane.switch", title: "Switch Pane", defaultKeys: [K(.tab), K(.tab, .shift)]) { _ in w?.switchPane() },
            C(id: "pane.open", title: "Open", defaultKeys: [K(.enter), K(.down, .command)]) { _ in pane()?.openCursor() },
            C(id: "pane.parent", title: "Parent Folder", defaultKeys: [K(.backspace), K(.up, .command)]) { _ in pane()?.goToParent() },
            C(id: "pane.reload", title: "Reread", defaultKeys: [K(.character("r"), .command)]) { ctx in
                guard let p = pane() else { return }
                p.model.reload(cursor: p.cursorPath)
                ctx.announce("Reread")
            },
            C(id: "pane.toggleHidden", title: "Show/Hide Hidden Files", defaultKeys: [K(.character("."), [.command, .shift])]) { ctx in
                guard let p = pane() else { return }
                p.model.setShowHidden(!p.model.showHidden, cursor: p.cursorPath)
                ctx.announce(p.model.showHidden ? "Showing hidden files" : "Hiding hidden files")
            },
            C(id: "pane.quickFilter", title: "Quick Filter", defaultKeys: [K(.character("s"), .command)]) { _ in pane()?.showQuickFilter() },
            C(id: "cursor.first", title: "First Item", defaultKeys: [K(.home)]) { _ in pane()?.moveCursor(to: 0) },
            C(id: "cursor.last", title: "Last Item", defaultKeys: [K(.end)]) { _ in pane()?.moveCursor(to: .max) },

            // Marking (Total Commander "selection"): the cursor and the marks are separate.
            C(id: "mark.toggle", title: "Mark/Unmark", defaultKeys: [K(.space)]) { _ in pane()?.toggleMarkAtCursor() },
            C(id: "mark.toggleDown", title: "Mark and Move Down", defaultKeys: [K(.down, .shift)]) { _ in pane()?.toggleMarkAtCursor(advance: 1) },
            C(id: "mark.toggleUp", title: "Mark and Move Up", defaultKeys: [K(.up, .shift)]) { _ in pane()?.toggleMarkAtCursor(advance: -1) },
            C(id: "mark.all", title: "Mark All Files", defaultKeys: [K(.character("a"), .command)]) { ctx in
                pane()?.model.markAllVisibleFiles()
                ctx.announce("\(pane()?.model.marked.count ?? 0) marked")
            },
            C(id: "mark.none", title: "Unmark All", defaultKeys: [K(.character("a"), [.command, .shift])]) { ctx in
                pane()?.model.unmarkAll()
                ctx.announce("All unmarked")
            },

            // Sorting (TC: Ctrl+F3...F6 -> Cmd+F3...F6).
            C(id: "sort.name", title: "Sort by Name", defaultKeys: [K(.function(3), .command)]) { _ in pane()?.setSort(.name) },
            C(id: "sort.ext", title: "Sort by Extension", defaultKeys: [K(.function(4), .command)]) { _ in pane()?.setSort(.ext) },
            C(id: "sort.date", title: "Sort by Date", defaultKeys: [K(.function(5), .command)]) { _ in pane()?.setSort(.modified) },
            C(id: "sort.size", title: "Sort by Size", defaultKeys: [K(.function(6), .command)]) { _ in pane()?.setSort(.size) },

            // File operations: implemented in later milestones (M2/M3).
            C(id: "file.view", title: "View", defaultKeys: [K(.function(3))], isEnabled: { _ in false }) { _ in },
            C(id: "file.edit", title: "Edit", defaultKeys: [K(.function(4))], isEnabled: { _ in false }) { _ in },
            C(id: "file.copy", title: "Copy", defaultKeys: [K(.function(5))], isEnabled: { _ in false }) { _ in },
            C(id: "file.move", title: "Move", defaultKeys: [K(.function(6))], isEnabled: { _ in false }) { _ in },
            C(id: "file.rename", title: "Rename", defaultKeys: [K(.function(6), .shift)], isEnabled: { _ in false }) { _ in },
            C(id: "file.mkdir", title: "New Folder", defaultKeys: [K(.function(7))], isEnabled: { _ in false }) { _ in },
            C(id: "file.delete", title: "Delete", defaultKeys: [K(.function(8)), K(.forwardDelete)], isEnabled: { _ in false }) { _ in },
            C(id: "file.multiRename", title: "Multi-Rename", defaultKeys: [K(.character("m"), .command)], isEnabled: { _ in false }) { _ in },
        ]
        commands.forEach(registry.register)
    }
}
