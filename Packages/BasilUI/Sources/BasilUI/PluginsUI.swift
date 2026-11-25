import AppKit
import BasilCore
import BasilOperations
import BasilPlugins
import BasilVFS
import SwiftUI

/// The main window as plugins see it: the panes, Basil's own operations through the queue and
/// dialogs as sheets.
extension MainWindowController: PluginHost {
    public var workspace: (any WorkspaceContext)? { self }

    public func enqueue(_ operation: any QueueOperation) { queue.add(operation) }

    /// Copies and moves a plugin asks for go to the queue at once, with the copy settings.
    public func transfer(_ sources: [VFSPath], to target: VFSPath, move: Bool) {
        guard !sources.isEmpty else { return }
        if target.location.container != nil || sources.contains(where: { $0.location.container != nil }) {
            return announce("Plugins cannot copy into or out of archives yet")
        }
        let s = settings.settings
        let options = SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries,
                                        secure: s.secureCopy)
        queue.add(TransferOperation(mode: move ? .move : .copy, sources: sources, target: target,
                                    registry: providers, options: options, administrator: administratorFiles))
    }

    /// Deletes a plugin asks for are confirmed first, like F8 and Shift+F8.
    public func delete(_ items: [VFSPath], toTrash: Bool) {
        guard !items.isEmpty, let window = NSApp.keyWindow ?? window else { return }
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        let canTrash = items.allSatisfy { ((try? providers.writableProvider(for: $0.location))?.capabilities.contains(.trash)) ?? false }
        let trash = toTrash && canTrash
        let alert = NSAlert()
        alert.messageText = trash ? "A plugin wants to move \(what) to the Trash." : "A plugin wants to delete \(what) permanently."
        if !trash { alert.informativeText = "This cannot be undone." }
        alert.alertStyle = trash ? .informational : .warning
        alert.addButton(withTitle: trash ? "Move to Trash" : "Delete")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await present(alert, in: window) == 0 else { return }
            queue.add(DeleteOperation(paths: items, toTrash: trash, registry: providers, administrator: administrator,
                                                   administratorFiles: administratorFiles))
        }
    }

    public func makeDirectory(_ path: VFSPath) {
        queue.add(MakeDirectoryOperation(path: path, registry: providers))
    }

    public func rename(_ path: VFSPath, to name: String) {
        guard let parent = path.parent else { return }
        queue.add(RenameOperation(source: path, destination: parent.appending(name), registry: providers))
    }

    public func ask(_ dialog: PluginDialog) async -> PluginDialogAnswer {
        guard let window = NSApp.keyWindow ?? window else { return .cancelled }
        let alert = NSAlert()
        switch dialog {
        case .text(let plugin, let message, let text):
            guard let answer = await askText(in: window, message: message, initial: text, confirm: "OK",
                                             fieldLabel: "\(plugin) asks") else { return .cancelled }
            return .text(answer)
        case .confirm(let plugin, let message, let button):
            alert.messageText = message
            alert.informativeText = "Asked by the plugin \(plugin)."
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            return await present(alert, in: window) == 0 ? .confirmed : .cancelled
        case .choose(let plugin, let message, let options):
            alert.messageText = message
            alert.informativeText = "Asked by the plugin \(plugin)."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            popup.addItems(withTitles: options)
            popup.setAccessibilityLabel("Choice")
            alert.accessoryView = popup
            alert.window.initialFirstResponder = popup
            let confirmed: Bool = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                alert.window.makeFirstResponder(popup)
            }
            return confirmed ? .chosen(popup.indexOfSelectedItem) : .cancelled
        case .permissions(let plugin, let permissions):
            alert.messageText = "Turn on \(plugin)?"
            alert.informativeText = "This plugin asks for more than Basil's own file operations: "
                + permissions.map(\.title).joined(separator: ", ")
                + ". Allow it only if you trust where it came from."
            alert.alertStyle = permissions.contains(.ffi) ? .critical : .warning
            alert.addButton(withTitle: "Allow and Turn On")
            alert.addButton(withTitle: "Cancel")
            return await present(alert, in: window) == 0 ? .confirmed : .cancelled
        }
    }

    public func pluginsChanged() {
        left.refreshAnnotations(after: .zero)
        right.refreshAnnotations(after: .zero)
    }
}

/// Settings > Plugins: every plugin in the Plugins folder with an on/off switch, what it may do,
/// whether it runs (or why not), Reload, Show in Finder and its log.
struct PluginSettings: View {
    let manager: PluginManager
    @State private var shownLogs: Set<String> = []

    var body: some View {
        Form {
            Text("Plugins are folders in \(manager.folder.path), each with a plugin.json and Lua code. A new plugin is off until you turn it on here; plugins that ask for network access, shell commands or LuaJIT's FFI ask first.")
                .font(.callout)
            HStack {
                Button("Open Plugins Folder") { NSWorkspace.shared.open(manager.folder) }
                Button("Look for Plugins") { manager.scan() }
            }
            if manager.entries.isEmpty {
                Text("No plugins installed.")
            }
            ForEach(manager.entries) { entry in
                let title = entry.manifest.map { "\($0.name) \($0.version)" } ?? entry.name
                let status = Self.status(entry)
                Section {
                    Toggle(title, isOn: Binding(get: { entry.isEnabled }, set: { on in
                        Task { await manager.setEnabled(entry.id, on) }
                    }))
                    .accessibilityLabel(title)
                    .disabled(entry.manifest == nil)
                    VStack(alignment: .leading, spacing: 4) {
                        if let description = entry.manifest?.description, !description.isEmpty {
                            Text(description)
                                .accessibilityLabel(description)
                        }
                        Text(status)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .accessibilityLabel(status)
                            .accessibilityIdentifier("plugin.status." + entry.id)
                    }
                    .accessibilityElement(children: .contain)
                    HStack {
                        Button("Reload Plugin") { Task { await manager.reload(entry.id) } }
                            .accessibilityLabel("Reload \(entry.name)")
                            .disabled(!entry.isEnabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                            .accessibilityLabel("Show \(entry.name) in Finder")
                        Button(shownLogs.contains(entry.id) ? "Hide Log" : "Show Log") {
                            if shownLogs.contains(entry.id) { shownLogs.remove(entry.id) } else { shownLogs.insert(entry.id) }
                        }
                        .accessibilityLabel(shownLogs.contains(entry.id) ? "Hide log of \(entry.name)" : "Show log of \(entry.name)")
                    }
                    if shownLogs.contains(entry.id) {
                        let text = entry.log.isEmpty ? "Nothing logged yet." : entry.log.suffix(30).joined(separator: "\n")
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel("Log of \(entry.name): \(text)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func status(_ entry: PluginManager.Entry) -> String {
        var parts: [String] = []
        if let problem = entry.problem {
            parts.append("Problem: " + (problem.split(separator: "\n").first.map(String.init) ?? problem))
        } else if entry.isLoaded {
            parts.append("Running")
        } else {
            parts.append("Off")
        }
        let wanted = entry.manifest?.wanted ?? []
        if wanted.isEmpty {
            parts.append("asks for nothing beyond Basil's own operations")
        } else {
            parts.append("asks for " + wanted.sorted().map { $0.title.lowercased() }.joined(separator: ", "))
            let granted = entry.granted.intersection(wanted)
            if !granted.isEmpty { parts.append("allowed: " + granted.sorted().map { $0.title.lowercased() }.joined(separator: ", ")) }
        }
        return parts.joined(separator: ". ") + "."
    }
}
