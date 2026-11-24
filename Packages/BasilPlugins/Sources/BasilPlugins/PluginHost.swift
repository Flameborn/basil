import BasilCore
import BasilOperations
import BasilVFS
import Foundation

/// The app's side of plugins (the main window): the panes, dialogs and Basil's own operations,
/// which go through the same paths as their keys (F5, F8, ...) so settings and prompts apply.
@MainActor
public protocol PluginHost: AnyObject {
    /// The window's panes for commands (cursor, selection, folders), nil while there is none.
    var workspace: (any WorkspaceContext)? { get }
    /// The folder the other pane shows.
    var otherDirectory: VFSPath? { get }
    func enqueue(_ operation: any QueueOperation)
    /// F5 / F6 to `target` (a folder).
    func transfer(_ sources: [VFSPath], to target: VFSPath, move: Bool)
    /// F8 (to the Trash where there is one) or Shift+F8.
    func delete(_ items: [VFSPath], toTrash: Bool)
    func makeDirectory(_ path: VFSPath)
    func rename(_ path: VFSPath, to name: String)
    func ask(_ dialog: PluginDialog) async -> PluginDialogAnswer
    func navigate(to directory: VFSPath)
    func announce(_ message: String)
    /// Columns, commands or menus of plugins changed (the panes and menus refresh).
    func pluginsChanged()
}

/// A question a plugin asks; shown as a sheet on the main window.
public enum PluginDialog: Sendable, Equatable {
    /// A text field, prefilled with `text`.
    case text(plugin: String, message: String, text: String)
    case confirm(plugin: String, message: String, button: String)
    case choose(plugin: String, message: String, options: [String])
    /// The permissions a plugin asks for when it is turned on.
    case permissions(plugin: String, permissions: [PluginPermission])
}

public enum PluginDialogAnswer: Sendable, Equatable {
    case cancelled
    case text(String)
    case confirmed
    case chosen(Int)
}
