import AppKit
import BasilCore
import BasilVFS

/// The pane context menu, like Total Commander's file context menu: right click, VO+Shift+M or
/// Shift+F10 on the cursor item. It is built from the command registry (`MenuLayout.contextMenu`),
/// so plugins add items the same way, and it leaves out commands that do not fit the items
/// (`Command.isApplicable`): Unpack only for archives, Copy Link only where the provider makes links.
/// Also the clipboard commands (Copy Link, Copy Path, Copy Name), which are in the Commands menu too.
@MainActor
enum ContextMenuCommands {
    static func register(in registry: CommandRegistry, window: MainWindowController) {
        typealias C = CommandRegistry.Command
        weak let w = window
        let commands = [
            C(id: "pane.contextMenu", title: "Show Context Menu", defaultKeys: [KeyChord(.function(10), .shift)]) { _ in
                w?.activePane.paneTable.showContextMenuAtCursor()
            },
            C(id: "file.copyLink", title: "Copy Link", isApplicable: { _ in w?.canCopyLinks ?? false }) { _ in
                w?.copyLinks()
            },
            C(id: "file.copyPath", title: "Copy Path", isApplicable: { _ in w?.hasTargets ?? false }) { _ in
                w?.copyToClipboard(\.clipboardPath, what: "Path")
            },
            C(id: "file.copyName", title: "Copy Name", isApplicable: { _ in w?.hasTargets ?? false }) { _ in
                w?.copyToClipboard(\.name, what: "Name")
            },
        ]
        commands.forEach(registry.register)
        for (id, check) in applicability(for: window) { registry.setApplicability(of: id, check) }
    }

    /// The built-in items, in the order of TC's (Explorer's) context menu.
    static func registerLayout(in layout: MenuLayout) {
        func c(_ ids: CommandID...) -> [MenuNode] { ids.map(MenuNode.command) }
        layout.addToContextMenu(
            c("pane.open", "file.view", "file.edit") + [.separator]
            + c("file.unpack", "file.testArchive", "file.pack") + [.separator]
            + c("file.copy", "file.move", "file.copyLink", "file.copyPath", "file.copyName") + [.separator]
            + c("file.rename", "file.delete", "file.deletePermanently") + [.separator]
            + c("file.mkdir", "file.newFile", "tools.terminal") + [.separator]
            + c("file.calculateSize", "file.info"))
    }

    /// Which built-in commands fit the current items. Commands not listed always fit.
    private static func applicability(for window: MainWindowController) -> [CommandID: @MainActor (any WorkspaceContext) -> Bool] {
        weak let w = window
        let hasTargets: @MainActor (any WorkspaceContext) -> Bool = { _ in w?.hasTargets ?? false }
        return [
            "pane.open": { _ in w?.canOpenCursor ?? false },
            "file.view": { _ in w?.cursorIsFile ?? false },
            "file.edit": { _ in w?.canEditCursor ?? false },
            "file.unpack": { _ in w?.targetsIncludeArchive ?? false },
            "file.testArchive": { _ in w?.targetsIncludeArchive ?? false },
            "file.pack": hasTargets,
            "file.copy": hasTargets,
            "file.move": hasTargets,
            "file.rename": hasTargets,
            "file.delete": hasTargets,
            "file.deletePermanently": hasTargets,
            "file.info": hasTargets,
            "file.calculateSize": { _ in w?.targetItems.contains(where: \.isDirectoryLike) ?? false },
            "tools.terminal": { _ in w?.activePane.model.directory.location == .local },
        ]
    }
}

extension FileItem {
    /// The path as people write it: "/Users/erion/a.txt", "/Users/erion/a.zip/docs/b.txt" inside an
    /// archive (like TC), "dropbox://erion@example.com/Photos" on a server.
    var clipboardPath: String { path.clipboardPath }
}

extension VFSPath {
    var clipboardPath: String {
        if let container = location.container {
            return isRoot ? container.clipboardPath : container.clipboardPath + path
        }
        return location == .local ? path : description
    }
}

extension MainWindowController {
    var hasTargets: Bool { !targetItems.isEmpty }

    var cursorIsFile: Bool {
        guard let item = activePane.cursorItem else { return false }
        return !item.isDirectoryLike
    }

    /// Enter does something: a folder, an archive, or a local file (opened with its app).
    var canOpenCursor: Bool {
        guard let item = activePane.cursorItem else { return false }
        return item.isDirectoryLike || providers.isContainer(item) || item.path.location == .local
    }

    /// F4 works on local files and files in archives (servers not yet).
    var canEditCursor: Bool {
        guard cursorIsFile, let item = activePane.cursorItem else { return false }
        return item.path.location == .local || item.path.location.container != nil
    }

    var targetsIncludeArchive: Bool {
        targetItems.contains { !$0.isDirectoryLike && providers.isContainer($0) }
    }

    private var linkProvider: (any SharedLinkProvider)? {
        try? providers.provider(for: activePane.model.directory.location) as? any SharedLinkProvider
    }

    var canCopyLinks: Bool { hasTargets && linkProvider != nil }

    /// Copy Path / Copy Name: the selected items (or the cursor item), one per line, like TC.
    func copyToClipboard(_ text: (FileItem) -> String, what: String) {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(text).joined(separator: "\n"), forType: .string)
        announce(items.count == 1 ? "\(what) copied" : "\(items.count) \(what.lowercased())s copied")
    }

    /// Copy Link: the provider's shared link of each selected item (or the cursor item), one per
    /// line. Dropbox makes a link where there is none yet.
    func copyLinks() {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        guard let provider = linkProvider else {
            return activePane.report("Links can only be made for files on a service that shares them, such as Dropbox")
        }
        let pane = activePane
        let slow = Task { [weak self] in
            try await Task.sleep(for: .seconds(1))
            self?.announce("Getting the link")
        }
        Task {
            defer { slow.cancel() }
            var links: [String] = []
            for item in items {
                do {
                    links.append(try await provider.sharedLink(for: item.path).absoluteString)
                } catch {
                    slow.cancel()
                    return pane.report(PaneViewController.describe(error))
                }
            }
            slow.cancel()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            announce(links.count == 1 ? "Link copied" : "\(links.count) links copied")
        }
    }

    /// The context menu for `pane`, which becomes the active pane.
    func contextMenu(for pane: PaneViewController) -> NSMenu? {
        if pane.side != activeSide { setActive(pane.side) }
        return menuBuilder?.contextMenu()
    }
}
