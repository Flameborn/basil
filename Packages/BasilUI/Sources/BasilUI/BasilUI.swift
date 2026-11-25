// BasilUI
//
// AppKit panes and main window, plus SwiftUI dialogs and settings.
// See CLAUDE.md for the architecture and progress.md for status.

import AppKit
import BasilCore
import BasilGit
import BasilIntegrations
import BasilOperations
import BasilPlugins
import BasilSearch
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
    /// Where app leftovers are searched (AppLeftoversSheet.swift); UI tests point it at the fixture.
    public var leftoverRoots: AppLeftoverFinder.Roots = .system
    /// Sign-ins on a website open the browser (UI tests turn it off).
    public var opensBrowser = true
    /// Removes items the user may not remove after macOS's password dialog (F8, Shift+F8).
    /// Nil in UI tests, where a permission error is just an error.
    public var administrator: AdministratorRemoval? = .system
    /// Copies and moves as an administrator through BasilHelper (F5, F6, Shift+F5). Nil in UI tests.
    public var administratorFiles: (any AdministratorFiles)?
    /// True while the "was changed, update it?" sheets are up (ArchiveEditing.swift).
    var offeringEditedCopies = false
    /// Questions of running queue items on screen (alert and the window it is a sheet of), so
    /// cancelling the item closes its question.
    var openPrompts: [ObjectIdentifier: (alert: NSAlert, window: NSWindow)] = [:]
    /// Host key and password questions of remote connections (`RemoteConnections.swift`).
    private(set) var remotePrompts: RemotePromptsUI!
    /// The system git, when found (Git column, Commands > Git). nil: no Git commands.
    public let git: GitService?
    /// Where server passwords (and Git logins) are remembered.
    let remoteSecrets: any SecretStore
    /// Unencrypted servers accepted with Connect Anyway while Basil runs.
    var unencryptedAcceptedNow: Set<String> = []
    /// The target each open connection was made with (bookmarks keep it to reconnect).
    var connectionTargets: [ProviderLocation: RemoteTarget] = [:]
    /// Find Files' engines (live walk, Spotlight, the own index; plugins add more).
    public let searchEngines: SearchEngines
    /// The Find Files window (Option+F7), kept with its last search while the app runs.
    var findWindow: FindFilesWindowController?
    /// The Synchronize Directories window, kept with its last comparison while the app runs.
    var syncWindow: SyncWindowController?
    /// Basil's own filename indexes (the startup disk and volumes ticked in Settings), when the app made them.
    public let searchIndexes: SearchIndexes?
    var searchIndexStatus: SearchIndexStatus?
    private var searchIndexToken: UUID?
    var themeToken: UUID?
    /// The Lua plugins (Settings > Plugins); set by the app, which starts them.
    public var plugins: PluginManager? {
        didSet {
            plugins?.host = self
            SettingsWindowController.plugins = plugins
        }
    }
    /// Updates from GitHub releases (`Updates.swift`).
    lazy var updates = UpdateCoordinator(window: self)

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
    /// - Parameter remoteSecrets: where server passwords and key passphrases are remembered; UI tests pass one in memory.
    /// - Parameter copiesDirectory: scratch folder for F3 / F4 copies of files inside archives.
    public init(providers: ProviderRegistry, commands: CommandRegistry, settings: SettingsStore,
                queue: FileOperationQueue, defaults: UserDefaults = .standard,
                startDirectories: (left: VFSPath, right: VFSPath)? = nil,
                dataDirectory: URL = MainWindowController.defaultDataDirectory,
                secrets: any SecretStore = Keychain.archivePasswords,
                remoteSecrets: any SecretStore = Keychain.remoteSecrets,
                copiesDirectory: URL = MainWindowController.defaultCopiesDirectory,
                git: GitService? = nil,
                searchEngines: SearchEngines = SearchEngines([LiveSearchEngine()]),
                searchIndexes: SearchIndexes? = nil) {
        self.dataDirectory = dataDirectory
        self.searchEngines = searchEngines
        self.searchIndexes = searchIndexes
        self.git = git
        self.remoteSecrets = remoteSecrets
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

        for pane in [left, right] {
            pane.commandBar.onRun = { [weak self, weak pane] text in
                guard let self, let pane else { return }
                runCommandLine(text, in: pane)
            }
        }
        BuiltinCommands.register(in: commands, window: self)
        ContextMenuCommands.register(in: commands, window: self)
        if git != nil { GitCommands.register(in: commands, window: self) }
        // The user's keys (Settings, Keys), saved whenever they change.
        commands.keyOverrides = settings.settings.keyBindings
        SettingsWindowController.commands = commands
        SettingsWindowController.checkForUpdates = { [weak self] in self?.checkForUpdates() }
        if let searchIndexes {
            // Automatic asks the index first; Spotlight is never picked by Automatic.
            searchEngines.register(IndexSearchEngine(indexes: searchIndexes.active), first: true)
            let status = SearchIndexStatus(indexes: searchIndexes, settings: settings)
            searchIndexStatus = status
            SettingsWindowController.searchIndex = status
        }
        functionBar = FunctionKeyBar(commands: commands, ids: BuiltinCommands.functionBarIDs)
        commands.onKeymapChange = { [weak self] in
            guard let self else { return }
            settings.settings.keyBindings = commands.keyOverrides
            functionBar.refreshKeys()
        }
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
            MainActor.assumeIsolated {
                self?.offerEditedCopies()
                self?.left.refreshAnnotations(after: .zero)
                self?.right.refreshAnnotations(after: .zero)
            }
        }
        followTheme()
        if searchIndexes != nil {
            searchIndexToken = settings.onChange { [weak self] _ in self?.applySearchIndexSetting() }
            applySearchIndexSetting()
            observeVolumesForSearchIndex()
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
        administratorFiles = HelperAccess(registry: providers, controller: self)
        remotePrompts = RemotePromptsUI(controller: self, secrets: remoteSecrets)
        queue.onEvent = { [weak self] event in self?.handle(event) }
        queue.promptHandler = { [weak self] item, prompt in
            guard let self else { return .conflict(.cancel) }
            let answer = await self.answer(prompt, for: item)
            progressWindow.promptAnswered(for: item)
            return answer
        }
        queue.promptCancelHandler = { [weak self] item in
            guard let open = self?.openPrompts[ObjectIdentifier(item)] else { return }
            open.window.endSheet(open.alert.window, returnCode: .abort)
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
        progressWindow.sizeFormat = { [weak self] in self?.settings.settings.size ?? SizeFormat() }
        progressWindow.placeName = { [weak self] in self?.placeName(of: $0) ?? $0.path }
        queue.onItemStarted = { [weak self] item in self?.progressWindow.itemStarted(item) }
        queue.onItemStopped = { [weak self] item in
            self?.progressWindow.itemStopped(item)
            self?.rereadRemotePanes()
            self?.left.refreshAnnotations()
            self?.right.refreshAnnotations()
            // Wait until the queue has started what comes next (whenDone may have queued it).
            Task { @MainActor in self?.closeUnusedContainers() }
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
        updateTitle()
    }

    /// "Downloads - Basil": the active pane's folder name, then the product name.
    /// "Downloads - Basil"; inside a Git repository with the branch: "Beta (main) - Basil".
    func updateTitle() {
        let branch = activePane.gitBranch.map { " (\($0))" } ?? ""
        let directory = activePane.model.directory
        let name = Listings.info(directory.location)?.title ?? directory.displayName
        window?.title = "\(name)\(branch) - Basil"
    }

    func paneDidUpdateAnnotations(_ pane: PaneViewController) {
        if pane === activePane { updateTitle() }
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

    func paneContextMenu(_ pane: PaneViewController) -> NSMenu? {
        contextMenu(for: pane)
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
        copies.dropPreviews(keeping: shownContainers, shownLocations: Set([left, right].map(\.model.directory.location)))
        closeUnusedContainers()
        if persistsDirectories {
            // Inside an archive, the folder holding it is remembered: providers do not survive a restart.
            let directory = Listings.info(pane.model.directory.location)?.origin ?? pane.model.directory
            let outermost = directory.outermostContainer
            let local = outermost == directory ? directory : outermost.parent
            if let local, local.location == .local { defaults.set(local.path, forKey: pane.side.defaultsKey) }
        }
    }

    func paneRequestsSettings(_ pane: PaneViewController) {
        showSettings(tab: .bookmarks)
    }

    func pane(_ pane: PaneViewController, open bookmark: Bookmark) {
        openBookmark(bookmark, in: pane)
    }

    func pane(_ pane: PaneViewController, remoteTargetFor location: ProviderLocation) -> RemoteTarget? {
        connectionTargets[location]
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
