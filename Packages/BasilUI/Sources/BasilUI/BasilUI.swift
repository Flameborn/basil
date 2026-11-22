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
    let commands: CommandRegistry
    let settings: SettingsStore
    let providers: ProviderRegistry
    let feedbackPlayer = EventFeedbackPlayer()
    let defaults: UserDefaults
    /// The single global operation queue (in memory only; it does not survive restarts).
    public let queue: FileOperationQueue
    private var queueWindow: QueueWindowController?
    /// Total Commander's progress dialog for the running item (`ProgressWindow.swift`).
    let progressWindow: ProgressWindowController
    let quickLook = QuickLookController()
    let left: PaneViewController
    let right: PaneViewController
    private var functionBar: FunctionKeyBar!
    var menuBuilder: CommandMenuBuilder?
    private(set) var activeSide: PaneSide = .left
    /// False when start folders were forced (UI tests), so test folders never become the user's saved start folders.
    private let persistsDirectories: Bool
    /// Basil's own files (for example the Multi-Rename undo log). UI tests pass a temporary folder.
    let dataDirectory: URL
    /// Local copies of files inside archives for F3 and F4 (`TemporaryCopies.swift`).
    let copies: TemporaryCopies
    /// True while the "was changed, update it?" sheets are up (ArchiveEditing.swift).
    var offeringEditedCopies = false

    /// ~/Library/Caches/Basil/Copies
    public static var defaultCopiesDirectory: URL { TemporaryCopies.defaultRoot }

    /// ~/Library/Application Support/Basil
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Basil", isDirectory: true)
    }

    /// - Parameter startDirectories: overrides the restored start folders (left, right).
    /// - Parameter dataDirectory: where Basil keeps its own files.
    /// - Parameter defaults: where pane state (folders, views) is remembered; UI tests pass an isolated domain.
    /// - Parameter secrets: where archive passwords are remembered; UI tests pass one in memory.
    /// - Parameter copiesDirectory: scratch folder for F3 / F4 copies of files inside archives.
    public init(providers: ProviderRegistry, commands: CommandRegistry, settings: SettingsStore,
                queue: FileOperationQueue, defaults: UserDefaults = .standard,
                startDirectories: (left: VFSPath, right: VFSPath)? = nil,
                dataDirectory: URL = MainWindowController.defaultDataDirectory,
                secrets: any SecretStore = Keychain.archivePasswords,
                copiesDirectory: URL = MainWindowController.defaultCopiesDirectory) {
        self.dataDirectory = dataDirectory
        self.copies = TemporaryCopies(root: copiesDirectory, registry: providers)
        self.progressWindow = ProgressWindowController(queue: queue)
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
        window.basilAutosave("BasilMainWindow")
        super.init(window: window)

        BuiltinCommands.register(in: commands, window: self)
        functionBar = FunctionKeyBar(commands: commands, ids: BuiltinCommands.functionBarIDs)
        functionBar.onInvoke = { [weak self] id in
            guard let self else { return }
            commands.perform(id, in: self)
        }

        window.contentViewController = WorkspaceViewController(left: left, right: right, functionBar: functionBar)
        if !BasilWindows.savesFrames || !window.setFrameUsingName("BasilMainWindow") {
            // No saved frame: 1280 by 800, or smaller to fit the screen, centred.
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = NSSize(width: min(1280, visible.width - 40), height: min(800, visible.height - 40))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }

        quickLook.announce = { [weak self] message in self?.announce(message) }
        quickLook.copies = copies
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerEditedCopies() }
        }
        for pane in [left, right] {
            pane.persistsTabs = persistsDirectories
            if persistsDirectories { pane.restoreTabs() }
            pane.delegate = self
            (pane.tableView as? PaneTableView)?.quickLook = quickLook
            pane.navigate(to: pane.model.directory)
        }
        setActive(.left)
        window.makeFirstResponder(left.tableView)
        installPasswordPrompt(secrets: secrets)
        queue.onEvent = { [weak self] event in self?.handle(event) }
        queue.promptHandler = { [weak self] item, prompt in
            guard let self else { return .conflict(.cancel) }
            let answer = await self.answer(prompt)
            progressWindow.promptAnswered(for: item)
            return answer
        }
        progressWindow.isAllowed = { [weak self] in
            guard let self else { return false }
            return settings.settings.showProgressWindow && queueWindow?.isOpen != true
        }
        progressWindow.returnFocus = { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(activePane.tableView)
        }
        progressWindow.showQueue = { [weak self] in self?.toggleQueue() }
        progressWindow.isQueueChord = { [weak self] chord in self?.commands.commandID(for: chord) == "queue.show" }
        progressWindow.announce = { [weak self] message in self?.announce(message) }
        queue.onItemStarted = { [weak self] item in self?.progressWindow.itemStarted(item) }
        queue.onItemStopped = { [weak self] item in self?.progressWindow.itemStopped(item) }
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
        updateTitle()
    }

    /// "Downloads - Basil": the active pane's folder name, then the product name.
    func updateTitle() {
        window?.title = "\(activePane.model.directory.displayName) - Basil"
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
        // The queue panel shows the same progress: send the progress window to the background.
        if progressWindow.isOpen { progressWindow.background() }
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
        quickLook.paneChanged(pane)
    }

    func pane(_ pane: PaneViewController, perform chord: KeyChord) -> Bool {
        if pane.side != activeSide { setActive(pane.side) }
        let handled = commands.perform(chord, in: self)
        // Space, Cmd+A and friends change what the Quick Look panel shows.
        if handled { quickLook.paneChanged(activePane) }
        return handled
    }

    func paneCursorDidChange(_ pane: PaneViewController) {
        if pane.side == activeSide { quickLook.paneChanged(pane) }
    }

    func pane(_ pane: PaneViewController, announce message: String) {
        announce(message)
    }

    /// Nothing is announced: VoiceOver reads the item under the cursor.
    func paneDidChangeDirectory(_ pane: PaneViewController) {
        if pane.side == activeSide { updateTitle() }
        copies.dropPreviews(keeping: shownContainers)
        if persistsDirectories {
            // Inside an archive, the folder holding it is remembered: providers do not survive a restart.
            let directory = pane.model.directory
            let outermost = directory.outermostContainer
            let local = outermost == directory ? directory : outermost.parent
            if let local, local.location == .local { defaults.set(local.path, forKey: pane.side.defaultsKey) }
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

/// Window frames are remembered in the standard preferences. UI tests turn this off, so they
/// never change the user's settings and always start from the same window positions.
@MainActor
public enum BasilWindows {
    public static var savesFrames = true
}

extension NSWindow {
    @MainActor func basilAutosave(_ name: String) {
        if BasilWindows.savesFrames { setFrameAutosaveName(name) }
    }
}
