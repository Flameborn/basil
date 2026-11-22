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
        func sorted(_ key: SortKey) -> @MainActor (any WorkspaceContext) -> Bool {
            { _ in pane()?.model.sortOrder.key == key }
        }
        func showing(_ viewID: String) -> @MainActor (any WorkspaceContext) -> Bool {
            { _ in pane()?.viewID == viewID }
        }

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
            C(id: "pane.toggleHidden", title: "Show Hidden Files", defaultKeys: [K(.character("."), [.command, .shift])],
              isChecked: { _ in pane()?.model.showHidden ?? false }) { ctx in
                guard let p = pane() else { return }
                p.model.setShowHidden(!p.model.showHidden, cursor: p.cursorPath)
                ctx.announce(p.model.showHidden ? "Showing hidden files" : "Hiding hidden files")
            },
            C(id: "pane.focusPath", title: "Go to Path Bar", defaultKeys: [K(.character("l"), .command)]) { _ in
                pane()?.focusPathBar()
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
            C(id: "select.allFiles", title: "Select All Files",
              defaultKeys: [K(.character("a"), .command), K(.numpad("+"), .command)]) { ctx in
                guard let p = pane() else { return }
                p.model.selectAllFiles()
                ctx.announce("Selected, \(itemCount(p.model.selected.count))")
            },
            C(id: "select.none", title: "Deselect All",
              defaultKeys: [K(.numpad("-"), .command), K(.character("-"), [.command, .shift])]) { ctx in
                pane()?.model.deselectAll()
                ctx.announce("Deselected")
            },
            // Total Commander's numpad keys.
            C(id: "select.group", title: "Select Group...", defaultKeys: [K(.numpad("+"))]) { _ in w?.selectGroup(true) },
            C(id: "select.ungroup", title: "Deselect Group...", defaultKeys: [K(.numpad("-"))]) { _ in w?.selectGroup(false) },
            C(id: "select.invert", title: "Invert Selection", defaultKeys: [K(.numpad("*"))]) { _ in w?.invertSelection() },
            C(id: "select.restore", title: "Restore Selection", defaultKeys: [K(.numpad("/"))]) { _ in w?.restoreSelection() },
            C(id: "select.sameExtension", title: "Select Files with Same Extension",
              defaultKeys: [K(.numpad("+"), .option)]) { _ in w?.selectSameExtension(true) },
            C(id: "select.deselectSameExtension", title: "Deselect Files with Same Extension",
              defaultKeys: [K(.numpad("-"), .option)]) { _ in w?.selectSameExtension(false) },

            // Views and sorting on Ctrl+Shift+F keys, in TC's Ctrl+F order (Option+F keys are actions).
            C(id: "view.brief", title: "Brief View", defaultKeys: [K(.function(1), [.control, .shift])], isChecked: showing(ListView.brief.id)) { _ in pane()?.setView(ListView.brief.id) },
            C(id: "view.full", title: "Full View", defaultKeys: [K(.function(2), [.control, .shift])], isChecked: showing(ListView.full.id)) { _ in pane()?.setView(ListView.full.id) },
            C(id: "sort.name", title: "Sort by Name", defaultKeys: [K(.function(3), [.control, .shift])], isChecked: sorted(.name)) { _ in pane()?.setSort(.name) },
            C(id: "sort.ext", title: "Sort by Extension", defaultKeys: [K(.function(4), [.control, .shift])], isChecked: sorted(.ext)) { _ in pane()?.setSort(.ext) },
            C(id: "sort.date", title: "Sort by Date", defaultKeys: [K(.function(5), [.control, .shift])], isChecked: sorted(.modified)) { _ in pane()?.setSort(.modified) },
            C(id: "sort.size", title: "Sort by Size", defaultKeys: [K(.function(6), [.control, .shift])], isChecked: sorted(.size)) { _ in pane()?.setSort(.size) },
            C(id: "sort.unsorted", title: "Unsorted", defaultKeys: [K(.function(7), [.control, .shift])], isChecked: sorted(.unsorted)) { _ in pane()?.setSort(.unsorted) },

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
                guard w.quickLook.isOpen || w.ensureReadable(w.activePane.model.directory) else { return }
                w.quickLook.toggle(for: w.activePane)
            },
            C(id: "file.edit", title: "Edit", defaultKeys: [K(.function(4))]) { _ in w?.editCursorItem() },
            C(id: "tools.terminal", title: "Open Terminal Here", defaultKeys: [K(.character("t"), [.command, .shift])]) { _ in
                w?.openTerminal()
            },
            C(id: "file.pack", title: "Pack", defaultKeys: [K(.function(5), .option)]) { _ in w?.packItems() },
            C(id: "file.unpack", title: "Unpack...", defaultKeys: [K(.function(9), .option)]) { _ in w?.unpackArchives() },
            // Split and combine like TC (no default keys there either).
            C(id: "file.split", title: "Split File...") { _ in w?.splitFile() },
            C(id: "file.combine", title: "Combine Files...") { _ in w?.combineFiles() },
            C(id: "file.testArchive", title: "Test Archives", defaultKeys: [K(.function(9), [.option, .shift])]) { _ in
                w?.testArchives()
            },
            // Checksum files like TC (no default keys there either).
            C(id: "file.checksumCreate", title: "Create Checksum Files...") { _ in w?.createChecksums() },
            C(id: "file.checksumVerify", title: "Verify Checksums") { _ in w?.verifyChecksums() },
            // ForkLift-style app cleanup; also offered after F8 / Shift+F8 of an app.
            C(id: "file.appLeftovers", title: "Find App Leftovers...") { _ in w?.findAppLeftovers() },
            C(id: "file.multiRename", title: "Multi-Rename", defaultKeys: [K(.character("m"), .command)]) { _ in
                w?.multiRename()
            },
        ]

        // Folder tabs (TC set, Mac keys).
        let multipleTabs: @MainActor (any WorkspaceContext) -> Bool = { _ in (pane()?.tabCount ?? 0) > 1 }
        commands += [
            C(id: "tab.new", title: "New Tab", defaultKeys: [K(.character("t"), .command)]) { _ in pane()?.newTab() },
            C(id: "tab.duplicate", title: "Duplicate Tab") { _ in pane()?.newTab(duplicate: true) },
            C(id: "tab.openCursorFolder", title: "Open Folder in New Tab", defaultKeys: [K(.up, [.command, .option])]) { ctx in
                guard let p = pane(), let item = p.cursorItem else { return }
                guard item.isDirectoryLike else { return ctx.announce("Not a folder") }
                p.newTab(at: item.path)
            },
            C(id: "tab.close", title: "Close Tab", defaultKeys: [K(.character("w"), .command)], isEnabled: multipleTabs) { _ in
                pane()?.closeTab()
            },
            C(id: "tab.closeOthers", title: "Close Other Tabs", isEnabled: multipleTabs) { _ in pane()?.closeOtherTabs() },
            C(id: "tab.next", title: "Next Tab", defaultKeys: [K(.tab, .control)], isEnabled: multipleTabs) { _ in
                pane()?.cycleTab(by: 1)
            },
            C(id: "tab.previous", title: "Previous Tab", defaultKeys: [K(.tab, [.control, .shift])], isEnabled: multipleTabs) { _ in
                pane()?.cycleTab(by: -1)
            },
            C(id: "tab.rename", title: "Rename Tab...") { _ in w?.renameTab() },
            C(id: "tab.lock", title: "Lock Tab", isChecked: { _ in pane()?.activeTab.locked ?? false }) { _ in
                pane()?.toggleTabLock()
            },
        ]
        for n in 1...9 {
            commands.append(C(id: CommandID(rawValue: "tab.goto\(n)"), title: "Go to Tab \(n)",
                              defaultKeys: [K(.character("\(n)"), .command)]) { _ in pane()?.goToTab(n) })
        }

        // Custom views 1-9 in settings order; 1-5 on Ctrl+Shift+F8 ... F12, 6-9 without a default key.
        for n in 1...9 {
            commands.append(C(id: CommandID(rawValue: "view.custom\(n)"), title: "Custom View \(n)",
                              defaultKeys: n <= 5 ? [K(.function(n + 7), [.control, .shift])] : [],
                              isEnabled: { _ in w?.customViewID(n) != nil },
                              menuTitle: { _ in w?.customViewID(n).flatMap { id in w?.settings.settings.view(id: id).name } },
                              isChecked: { _ in w?.customViewID(n).map { pane()?.viewID == $0 } ?? false }) { _ in
                if let id = w?.customViewID(n) { pane()?.setView(id) }
            })
        }
        // Net: Cmd+K's connection manager, Disconnect, and the saved connections 1-20 by name.
        commands.append(C(id: "net.connect", title: "Connect to Server...", defaultKeys: [K(.character("k"), .command)]) { _ in
            w?.showConnections()
        })
        commands.append(C(id: "net.disconnect", title: "Disconnect", defaultKeys: [K(.character("k"), [.command, .shift])],
                          isEnabled: { _ in w?.activeConnection != nil },
                          menuTitle: { _ in w?.activeConnection.map { "Disconnect \($0.connectionTitle)" } ?? "Disconnect" }) { _ in
            w?.disconnectActive()
        })
        for n in 1...20 {
            func saved() -> SavedConnection? {
                guard let list = w?.settings.settings.connections, list.indices.contains(n - 1) else { return nil }
                return list[n - 1]
            }
            commands.append(C(id: CommandID(rawValue: "net.saved\(n)"), title: "Saved Connection \(n)",
                              isEnabled: { _ in saved() != nil },
                              menuTitle: { _ in saved().map { w?.connectionTitle($0) ?? $0.title } }) { _ in
                if let connection = saved() { w?.connect(connection.target, saved: connection.id) }
            })
        }
        commands.forEach(registry.register)
    }
}
