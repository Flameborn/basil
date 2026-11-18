// BasilUI
//
// AppKit panes and main window, plus SwiftUI dialogs and settings.
// See CLAUDE.md for the architecture and progress.md for status.

import AppKit
import BasilCore
import BasilVFS

/// The main dual-pane window. Owns both panes, tracks the active one, and is the
/// `WorkspaceContext` that commands (built-in and plugin) operate on.
@MainActor
public final class MainWindowController: NSWindowController, WorkspaceContext {
    private let commands: CommandRegistry
    private let left: PaneViewController
    private let right: PaneViewController
    private var functionBar: FunctionKeyBar!
    private(set) var activeSide: PaneSide = .left
    /// False when start folders were forced (UI tests), so test folders never become the user's saved start folders.
    private let persistsDirectories: Bool

    /// - Parameter startDirectories: overrides the restored start folders (left, right).
    public init(providers: ProviderRegistry, commands: CommandRegistry,
                startDirectories: (left: VFSPath, right: VFSPath)? = nil) {
        self.commands = commands
        self.persistsDirectories = startDirectories == nil
        let defaults = UserDefaults.standard
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        func restored(_ side: PaneSide) -> VFSPath {
            if let start = startDirectories { return side == .left ? start.left : start.right }
            return defaults.string(forKey: side.defaultsKey).map(VFSPath.local) ?? home
        }
        left = PaneViewController(side: .left, model: PaneModel(registry: providers, directory: restored(.left)))
        right = PaneViewController(side: .right, model: PaneModel(registry: providers, directory: restored(.right)))

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

    func switchPane() {
        let target = otherPane
        window?.makeFirstResponder(target.tableView) // becomes active via first-responder callback
        announce("\(target.side.accessibilityLabel), \(target.directorySummary)")
    }

    // MARK: WorkspaceContext

    public var activeDirectory: VFSPath? { activePane.model.directory }
    public var otherDirectory: VFSPath? { otherPane.model.directory }
    public var cursorItem: FileItem? { activePane.cursorItem }

    public var targetItems: [FileItem] {
        let marked = activePane.model.markedItems
        if !marked.isEmpty { return marked }
        return activePane.cursorItem.map { [$0] } ?? []
    }

    public func navigate(to directory: VFSPath) {
        activePane.navigate(to: directory)
    }

    public func announce(_ message: String) {
        guard let window else { return }
        NSAccessibility.post(
            element: window,
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

    func paneDidChangeDirectory(_ pane: PaneViewController) {
        if persistsDirectories {
            UserDefaults.standard.set(pane.model.directory.path, forKey: pane.side.defaultsKey)
        }
        if pane.side == activeSide { announce(pane.directorySummary) }
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
