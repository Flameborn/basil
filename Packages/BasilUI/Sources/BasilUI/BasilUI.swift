// BasilUI
//
// AppKit panes and main window, plus SwiftUI dialogs and settings.
// See CLAUDE.md for the architecture and progress.md for status.

import AppKit
import BasilCore
import BasilIntegrations
import BasilOperations
import BasilVFS

/// The main dual-pane window. Owns both panes, tracks the active one, and is the
/// `WorkspaceContext` that commands (built-in and plugin) operate on.
@MainActor
public final class MainWindowController: NSWindowController, WorkspaceContext {
    private let commands: CommandRegistry
    let settings: SettingsStore
    let providers: ProviderRegistry
    let feedbackPlayer = EventFeedbackPlayer()
    private let defaults: UserDefaults
    /// The single global operation queue (in memory only; it does not survive restarts).
    public let queue: FileOperationQueue
    private var queueWindow: QueueWindowController?
    private let left: PaneViewController
    private let right: PaneViewController
    private var functionBar: FunctionKeyBar!
    private(set) var activeSide: PaneSide = .left
    /// False when start folders were forced (UI tests), so test folders never become the user's saved start folders.
    private let persistsDirectories: Bool
    /// Basil's own files (for example the Multi-Rename undo log). UI tests pass a temporary folder.
    let dataDirectory: URL

    /// ~/Library/Application Support/Basil
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Basil", isDirectory: true)
    }

    /// - Parameter startDirectories: overrides the restored start folders (left, right).
    /// - Parameter dataDirectory: where Basil keeps its own files.
    /// - Parameter defaults: where pane state (folders, views) is remembered; UI tests pass an isolated domain.
    public init(providers: ProviderRegistry, commands: CommandRegistry, settings: SettingsStore,
                queue: FileOperationQueue, defaults: UserDefaults = .standard,
                startDirectories: (left: VFSPath, right: VFSPath)? = nil,
                dataDirectory: URL = MainWindowController.defaultDataDirectory) {
        self.dataDirectory = dataDirectory
        self.commands = commands
        self.settings = settings
        self.providers = providers
        self.defaults = defaults
        self.queue = queue
        self.persistsDirectories = startDirectories == nil
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        func restored(_ side: PaneSide) -> VFSPath {
            if let start = startDirectories { return side == .left ? start.left : start.right }
            return defaults.string(forKey: side.defaultsKey).map(VFSPath.local) ?? home
        }
        left = PaneViewController(side: .left, model: PaneModel(registry: providers, directory: restored(.left)), settings: settings, defaults: defaults)
        right = PaneViewController(side: .right, model: PaneModel(registry: providers, directory: restored(.right)), settings: settings, defaults: defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Basil"
        window.setFrameAutosaveName("BasilMainWindow")
        super.init(window: window)

        BuiltinCommands.register(in: commands, window: self)
        functionBar = FunctionKeyBar(commands: commands, ids: BuiltinCommands.functionBarIDs)
        functionBar.onInvoke = { [weak self] id in
            guard let self else { return }
            commands.perform(id, in: self)
        }

        window.contentViewController = WorkspaceViewController(left: left, right: right, functionBar: functionBar)
        if !window.setFrameUsingName("BasilMainWindow") { window.center() }

        for pane in [left, right] {
            pane.delegate = self
            pane.navigate(to: pane.model.directory)
        }
        setActive(.left)
        window.makeFirstResponder(left.tableView)
        queue.onEvent = { [weak self] event in self?.handle(event) }
        queue.promptHandler = { [weak self] _, prompt in
            guard let self else { return .conflict(.cancel) }
            return await self.answer(prompt)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Panes

    var activePane: PaneViewController { activeSide == .left ? left : right }
    var otherPane: PaneViewController { activeSide == .left ? right : left }

    func setActive(_ side: PaneSide) {
        activeSide = side
        left.isActive = side == .left
        right.isActive = side == .right
        functionBar.updateEnabled { [unowned self] id in commands.command(id)?.isEnabled(self) ?? false }
    }

    /// Tab: VoiceOver already reads the focused list's label ("Left pane"/"Right pane"), so nothing extra is announced.
    func switchPane() {
        window?.makeFirstResponder(otherPane.tableView) // becomes active via first-responder callback
    }

    func showLocationsMenu(for side: PaneSide) {
        let pane = side == .left ? left : right
        window?.makeFirstResponder(pane.tableView)
        pane.showLocationsMenu()
    }

    /// The id of the n-th (1-based) custom view, in settings order.
    func customViewID(_ n: Int) -> String? {
        let custom = settings.settings.views.filter { !$0.isBuiltin }
        return custom.indices.contains(n - 1) ? custom[n - 1].id : nil
    }

    /// Cmd+J: opens the queue panel, or closes it when it is open.
    func toggleQueue() {
        let controller = queueWindow ?? QueueWindowController(
            queue: queue,
            isToggleChord: { [weak self] chord in self?.commands.commandID(for: chord) == "queue.show" },
            announce: { [weak self] message in self?.announce(message) }
        )
        queueWindow = controller
        if controller.isOpen, controller.window?.isKeyWindow == true {
            controller.close()
        } else {
            controller.show()
        }
    }

    func showSettings(tab: SettingsTab = .views) {
        SettingsWindowController.show(settings: settings, tab: tab)
    }

    // MARK: WorkspaceContext

    public var activeDirectory: VFSPath? { activePane.model.directory }
    public var otherDirectory: VFSPath? { otherPane.model.directory }
    public var cursorItem: FileItem? { activePane.cursorItem }

    public var targetItems: [FileItem] {
        let marked = activePane.model.selectedItems
        if !marked.isEmpty { return marked }
        return activePane.cursorItem.map { [$0] } ?? []
    }

    public func navigate(to directory: VFSPath) {
        activePane.navigate(to: directory)
    }

    public func announce(_ message: String) {
        // The app, not the main window: announcements must also be heard while the queue panel is key.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

extension MainWindowController: PaneViewControllerDelegate {
    func paneDidBecomeActive(_ pane: PaneViewController) {
        if pane.side != activeSide { setActive(pane.side) }
    }

    func pane(_ pane: PaneViewController, perform chord: KeyChord) -> Bool {
        if pane.side != activeSide { setActive(pane.side) }
        return commands.perform(chord, in: self)
    }

    func pane(_ pane: PaneViewController, announce message: String) {
        announce(message)
    }

    /// Nothing is announced: VoiceOver reads the item under the cursor.
    func paneDidChangeDirectory(_ pane: PaneViewController) {
        if persistsDirectories {
            defaults.set(pane.model.directory.path, forKey: pane.side.defaultsKey)
        }
    }

    func paneRequestsSettings(_ pane: PaneViewController) {
        showSettings(tab: .bookmarks)
    }
}

extension PaneSide {
    var defaultsKey: String { "pane.\(identifier).directory" }
}

/// Two panes side by side above the function-key bar.
@MainActor
final class WorkspaceViewController: NSViewController {
    private let split = NSSplitViewController()
    private let left: PaneViewController
    private let right: PaneViewController
    private let functionBar: FunctionKeyBar

    init(left: PaneViewController, right: PaneViewController, functionBar: FunctionKeyBar) {
        self.left = left
        self.right = right
        self.functionBar = functionBar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        for pane in [left, right] {
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 280
            split.addSplitViewItem(item)
        }
        addChild(split)
        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        functionBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        root.addSubview(functionBar)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            functionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            functionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            functionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root
    }
}
