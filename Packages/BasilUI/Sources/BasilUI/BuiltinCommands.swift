import BasilCore
import Foundation

/// Built-in pane and navigation commands with their default (Total Commander, Mac-adapted) keys.
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var commands: [C] = [
            C(id: "pane.switch", title: "Switch Pane", defaultKeys: [K(.tab), K(.tab, .shift)]) { _ in w?.switchPane() },
            C(id: "pane.open", title: "Open", defaultKeys: [K(.enter), K(.down, .command)]) { _ in pane()?.openCursor() },
            C(id: "pane.openArchive", title: "Open as Archive", defaultKeys: [K(.pageDown, .command)]) { _ in
                pane()?.openCursorAsContainer()
            },
            C(id: "pane.parent", title: "Parent Folder", defaultKeys: [K(.backspace), K(.up, .command)]) { _ in pane()?.goToParent() },
            C(id: "pane.reload", title: "Reread", defaultKeys: [K(.function(2))]) { ctx in
                guard let p = pane() else { return }
                p.model.reload(cursor: p.cursorPath)
                ctx.announce("Reread")
            },
            C(id: "pane.toggleHidden", title: "Show or Hide Hidden Files", defaultKeys: [K(.character("."), [.command, .shift])]) { ctx in
                guard let p = pane() else { return }
                p.model.setShowHidden(!p.model.showHidden, cursor: p.cursorPath)
                ctx.announce(p.model.showHidden ? "Showing hidden files" : "Hiding hidden files")
            },
            C(id: "pane.quickFilter", title: "Quick Filter", defaultKeys: [K(.character("s"), .command)]) { _ in pane()?.showQuickFilter() },
            C(id: "pane.readStatus", title: "Read Status Bar", defaultKeys: [K(.character("i"), .option)]) { ctx in
                guard let p = pane() else { return }
                ctx.announce(p.statusText)
            },
            C(id: "pane.locations", title: "Locations and Bookmarks", defaultKeys: [K(.character("d"), .command)]) { _ in
                pane()?.showLocationsMenu()
            },
            C(id: "pane.locationsLeft", title: "Left Pane Locations", defaultKeys: [K(.function(1), .command)]) { _ in
                w?.showLocationsMenu(for: .left)
            },
            C(id: "pane.locationsRight", title: "Right Pane Locations", defaultKeys: [K(.function(2), .command)]) { _ in
                w?.showLocationsMenu(for: .right)
            },
            // Go (Finder's Go menu keys). Cmd+G asks for a path, with suggestions.
            C(id: "go.path", title: "Go to Folder or File",
              defaultKeys: [K(.character("g"), .command), K(.character("g"), [.command, .shift])]) { _ in w?.goToPath() },
            C(id: "go.home", title: "Go to Home", defaultKeys: [K(.character("h"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local(home))
            },
            C(id: "go.desktop", title: "Go to Desktop", defaultKeys: [K(.character("d"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local(home + "/Desktop"))
            },
            C(id: "go.documents", title: "Go to Documents", defaultKeys: [K(.character("o"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local(home + "/Documents"))
            },
            C(id: "go.downloads", title: "Go to Downloads", defaultKeys: [K(.character("l"), [.command, .option])]) { _ in
                pane()?.navigate(to: .local(home + "/Downloads"))
            },
            C(id: "go.applications", title: "Go to Applications", defaultKeys: [K(.character("a"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local("/Applications"))
            },
            C(id: "go.utilities", title: "Go to Utilities", defaultKeys: [K(.character("u"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local("/Applications/Utilities"))
            },
            C(id: "go.iCloud", title: "Go to iCloud Drive", defaultKeys: [K(.character("i"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local(home + "/Library/Mobile Documents/com~apple~CloudDocs"))
            },
            C(id: "go.computer", title: "Go to Volumes", defaultKeys: [K(.character("c"), [.command, .shift])]) { _ in
                pane()?.navigate(to: .local("/Volumes"))
            },
            C(id: "cursor.first", title: "First Item", defaultKeys: [K(.home)]) { _ in pane()?.moveCursor(to: 0) },
            C(id: "cursor.last", title: "Last Item", defaultKeys: [K(.end)]) { _ in pane()?.moveCursor(to: .max) },

            // Selection (Total Commander "marking"): the cursor and the selection are separate.
            C(id: "select.toggle", title: "Select or Deselect", defaultKeys: [K(.space)]) { _ in pane()?.toggleSelectionAtCursor() },
            C(id: "select.toggleDown", title: "Select and Move Down", defaultKeys: [K(.down, .shift)]) { _ in pane()?.toggleSelectionAtCursor(advance: 1) },
            C(id: "select.toggleUp", title: "Select and Move Up", defaultKeys: [K(.up, .shift)]) { _ in pane()?.toggleSelectionAtCursor(advance: -1) },
            C(id: "select.allFiles", title: "Select All Files", defaultKeys: [K(.character("a"), .command)]) { ctx in
                guard let p = pane() else { return }
                p.model.selectAllFiles()
                ctx.announce("Selected, \(itemCount(p.model.selected.count))")
            },
            C(id: "select.none", title: "Deselect All",
              defaultKeys: [K(.numpad("-")), K(.character("-"), [.command, .shift])]) { ctx in
                pane()?.model.deselectAll()
                ctx.announce("Deselected")
            },

            // Sorting (TC: Ctrl+F3-F6 -> Cmd+F3-F6).
            C(id: "sort.name", title: "Sort by Name", defaultKeys: [K(.function(3), .command)]) { _ in pane()?.setSort(.name) },
            C(id: "sort.ext", title: "Sort by Extension", defaultKeys: [K(.function(4), .command)]) { _ in pane()?.setSort(.ext) },
            C(id: "sort.date", title: "Sort by Date", defaultKeys: [K(.function(5), .command)]) { _ in pane()?.setSort(.modified) },
            C(id: "sort.size", title: "Sort by Size", defaultKeys: [K(.function(6), .command)]) { _ in pane()?.setSort(.size) },

            // Views (TC: Ctrl+F1 brief, Ctrl+F2 full; custom views from Ctrl+F3).
            C(id: "view.brief", title: "Brief View", defaultKeys: [K(.function(1), .control)]) { _ in pane()?.setView(ListView.brief.id) },
            C(id: "view.full", title: "Full View", defaultKeys: [K(.function(2), .control)]) { _ in pane()?.setView(ListView.full.id) },

            C(id: "queue.show", title: "Operation Queue", defaultKeys: [K(.character("j"), .command)]) { _ in w?.toggleQueue() },
            C(id: "app.settings", title: "Settings", defaultKeys: [K(.character(","), .command)]) { _ in w?.showSettings() },

            // File operations. All of them go through the queue.
            C(id: "file.copy", title: "Copy", defaultKeys: [K(.function(5))]) { _ in w?.copyOrMove(.copy) },
            C(id: "file.move", title: "Move", defaultKeys: [K(.function(6))]) { _ in w?.copyOrMove(.move) },
            // Shift+F6 with several items selected opens the Multi-Rename tool.
            C(id: "file.rename", title: "Rename", defaultKeys: [K(.function(6), .shift)]) { _ in
                if (pane()?.model.selected.count ?? 0) > 1 { w?.multiRename() } else { w?.renameCursorItem() }
            },
            C(id: "file.newFile", title: "New File", defaultKeys: [K(.function(4), .shift)]) { _ in w?.newFile() },
            C(id: "file.info", title: "Get Info", defaultKeys: [K(.character("i"), .command)]) { _ in w?.showInfo() },
            C(id: "file.calculateSize", title: "Calculate Folder Size", defaultKeys: [K(.character("s"), [.command, .shift])]) { _ in
                guard let w else { return }
                w.activePane.calculateSizes(of: w.targetItems)
            },
            C(id: "file.mkdir", title: "New Folder", defaultKeys: [K(.function(7))]) { _ in w?.makeDirectory() },
            C(id: "file.delete", title: "Delete", defaultKeys: [K(.function(8)), K(.forwardDelete)]) { _ in
                w?.delete(permanently: false)
            },
            C(id: "file.deletePermanently", title: "Delete Permanently",
              defaultKeys: [K(.function(8), .shift), K(.forwardDelete, .shift)]) { _ in
                w?.delete(permanently: true)
            },

            // F3 Quick Look (F3 again or Escape closes it), F4 edit with the editor rules from Settings.
            C(id: "file.view", title: "View", defaultKeys: [K(.function(3))]) { _ in
                guard let w else { return }
                w.quickLook.toggle(for: w.activePane)
            },
            C(id: "file.edit", title: "Edit", defaultKeys: [K(.function(4))]) { _ in w?.editCursorItem() },
            C(id: "tools.terminal", title: "Open Terminal Here", defaultKeys: [K(.character("t"), [.command, .shift])]) { _ in
                w?.openTerminal()
            },
            C(id: "file.pack", title: "Pack", defaultKeys: [K(.function(5), .option)]) { _ in w?.packItems() },
            C(id: "file.testArchive", title: "Test Archives", defaultKeys: [K(.function(9), [.option, .shift])]) { _ in
                w?.testArchives()
            },
            C(id: "file.multiRename", title: "Multi-Rename", defaultKeys: [K(.character("m"), .command)]) { _ in
                w?.multiRename()
            },
        ]

        // Custom views 1-9 on Ctrl+F3 ... Ctrl+F11, in the order they appear in settings.
        for n in 1...9 {
            commands.append(C(id: CommandID(rawValue: "view.custom\(n)"), title: "Custom View \(n)",
                              defaultKeys: [K(.function(n + 2), .control)],
                              isEnabled: { _ in w?.customViewID(n) != nil }) { _ in
                if let id = w?.customViewID(n) { pane()?.setView(id) }
            })
        }
        commands.forEach(registry.register)
    }
}
