import AppKit
import BasilArchives
import BasilCore
import BasilGit
import BasilIntegrations
import BasilOperations
import BasilRemote
import BasilSearch
import BasilUI
import BasilVFS

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private let providers = ProviderRegistry()
    private let commands = CommandRegistry()
    private var settings = SettingsStore()
    private let queue = FileOperationQueue()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(settingsTarget: self)
        #if DEBUG
        DebugMenu.install(queue: queue)
        #endif
        // A file manager needs to read every folder: until macOS grants Full Disk Access, only the
        // permission window shows (Quit, Open System Settings, Continue once granted).
        var check: @MainActor () -> FullDiskAccess.Status = { FullDiskAccess.status() }
        #if DEBUG
        // UI tests (whose runner may lack the grant) skip the check, unless BASIL_UITEST_FDA=1:
        // then access counts as granted three seconds after the window opened.
        if UITestFixture.isActive {
            if ProcessInfo.processInfo.environment["BASIL_UITEST_FDA"] == "1" {
                var opened: Date?
                check = {
                    let start = opened ?? Date()
                    opened = start
                    return Date().timeIntervalSince(start) >= 3 ? .granted : .notGranted
                }
            } else {
                check = { .granted }
            }
        }
        #endif
        FullDiskAccessWindowController.runIfNeeded(check: check) { [weak self] in self?.start() }
    }

    private func start() {
        providers.register(LocalProvider())
        let archives = ArchiveOpener() // UnRAR (linked in) and libarchive
        // 7z through the 7zz built from Vendor/7zip and copied into Contents/MacOS.
        // Zip files libarchive cannot read fall back to 7-Zip, tried after libarchive.
        if let sevenZip = SevenZipBackend.bundled() {
            archives.register(sevenZip)
            archives.register(sevenZip.zipFallback(), first: false)
        }
        providers.register(opener: archives)
        providers.register(writer: archives)
        // File lists (.lst) like TC's DiskDir: browsed like folders, written by the pack dialog.
        let fileLists = FileListOpener()
        providers.register(opener: fileLists)
        providers.register(writer: fileLists)
        // The Git column: status of items in local working trees, through the system git.
        // Logins for pull and push are asked by this executable started as git's askpass program.
        let git = GitService.findExecutable().map { GitService(executable: $0, askPassExecutable: Bundle.main.executablePath) }
        if let git {
            providers.register(annotator: GitAnnotator(git: git))
            GitOperationKinds.register()
        }
        // Remote services: SFTP (libssh2 with OpenSSL, from Vendor/libssh2); FTP below.
        providers.register(connector: SFTPConnector())
        var start: (left: VFSPath, right: VFSPath)?
        var defaults = UserDefaults.standard
        var dataDirectory = MainWindowController.defaultDataDirectory
        var secrets: any SecretStore = Keychain.archivePasswords
        var remoteSecrets: any SecretStore = Keychain.remoteSecrets
        var copiesDirectory = MainWindowController.defaultCopiesDirectory
        #if DEBUG
        start = UITestFixture.makeIfRequested()
        if let isolated = UITestFixture.isolatedDefaults() {
            defaults = isolated
            BasilWindows.savesFrames = false
            dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("basil-uitest-data", isDirectory: true)
            try? FileManager.default.removeItem(at: dataDirectory)
            copiesDirectory = dataDirectory.appendingPathComponent("Copies", isDirectory: true)
            settings = SettingsStore(defaults: isolated)
            secrets = MemorySecretStore() // UI tests never touch the user's keychain
            remoteSecrets = MemorySecretStore()
            // The progress window takes focus, which would swallow the keys of other tests.
            settings.settings.showProgressWindow = ProcessInfo.processInfo.environment["BASIL_UITEST_PROGRESS"] == "1"
            if let server = UITestSSHServer.startIfRequested(), let root = start?.left {
                providers.register(connector: SFTPConnector(home: server.home, knownHostsFile: server.knownHosts,
                                                            agentSocket: server.home.appendingPathComponent("no-agent").path,
                                                            defaultKeys: false))
                settings.settings.connections = [SavedConnection(
                    name: "Test server",
                    target: RemoteTarget(service: .sftp, host: "127.0.0.1", port: server.port, user: NSUserName(),
                                         path: root.path, authentication: .keyFile(server.key)))]
            }
            if let root = start?.left, let server = UITestWebDAVServer.startIfRequested(serving: root.path) {
                settings.settings.connections = [SavedConnection(
                    name: "Test WebDAV server",
                    target: RemoteTarget(service: .webdavs, host: "127.0.0.1", port: server.port, user: server.user,
                                         path: "/dav", authentication: .password))]
            }
            if let server = UITestSMBServer.startIfRequested() {
                settings.settings.connections = [SavedConnection(
                    name: "Test SMB server",
                    target: RemoteTarget(service: .smb, host: server.host, port: nil, user: server.user,
                                         path: nil, authentication: .password))]
            }
            if let server = UITestS3Server.startIfRequested() {
                settings.settings.connections = [SavedConnection(
                    name: "Test S3 server",
                    target: RemoteTarget(service: .s3, host: server.host, port: server.port, user: server.accessKey,
                                         path: nil, authentication: .password, options: ["security": "http"]))]
            }
            if let server = UITestFTPServer.startIfRequested(), let root = start?.left {
                settings.settings.connections = [SavedConnection(
                    name: "Test FTP server",
                    target: RemoteTarget(service: .ftpes, host: "127.0.0.1", port: server.port, user: server.user,
                                         path: root.path, authentication: .password))]
            }
            // UI tests run silently (no sounds, no system voice).
            for outcome in QueueOutcome.allCases {
                settings.settings.feedback.defaults[outcome.rawValue] = EventFeedback(sound: .none, speak: false, text: "")
            }
        }
        #endif
        // FTP and FTPS: Basil's own client (OpenSSL's libssl for TLS). Certificates the user
        // trusts are remembered in the data folder.
        let trustFile = dataDirectory.appendingPathComponent("Trusted FTP certificates.txt")
        for kind in [FTPConnector.Kind.plain, .explicitTLS, .implicitTLS] {
            providers.register(connector: FTPConnector(kind, trustFile: trustFile))
        }
        // WebDAV over HTTP and HTTPS (URLSession), with Nextcloud's extras where the server is one.
        let davTrustFile = dataDirectory.appendingPathComponent("Trusted WebDAV certificates.txt")
        providers.register(connector: WebDAVConnector(secure: true, trustFile: davTrustFile))
        providers.register(connector: WebDAVConnector(secure: false, trustFile: davTrustFile))
        // SMB through macOS's own client: shares are mounted in /Volumes like Finder does.
        providers.register(connector: SMBConnector())
        // Amazon S3 and S3-compatible services (R2, B2, Wasabi, MinIO, ...), Basil's own SigV4 client.
        providers.register(connector: S3Connector(trustFile: dataDirectory.appendingPathComponent("Trusted S3 certificates.txt")))
        // Dropbox, when the build has an app key (Config/Dropbox.local.xcconfig). Its sign-in comes
        // back to http://localhost:21745/dropbox, which Basil serves while it waits.
        if let key = Bundle.main.object(forInfoDictionaryKey: "BasilDropboxAppKey") as? String,
           !key.isEmpty, !key.hasPrefix("$(") {
            providers.register(connector: DropboxConnector(appKey: key, secrets: remoteSecrets))
        }
        // Google Drive, when the build has an OAuth client (Config/GoogleDrive.local.xcconfig).
        let info = Bundle.main.infoDictionary ?? [:]
        if let id = info["BasilGoogleClientID"] as? String, let secret = info["BasilGoogleClientSecret"] as? String,
           !id.isEmpty, !id.hasPrefix("$("), !secret.hasPrefix("$(") {
            providers.register(connector: GoogleDriveConnector(client: GoogleClient(id: id, secret: secret), secrets: remoteSecrets))
        }
        // OneDrive, when the build has a Microsoft Entra client ID (Config/OneDrive.local.xcconfig).
        if let id = info["BasilOneDriveClientID"] as? String, !id.isEmpty, !id.hasPrefix("$(") {
            providers.register(connector: OneDriveConnector(clientID: id, secrets: remoteSecrets))
        }
        #if DEBUG
        // UI tests see Dropbox, Google Drive and OneDrive in every build; their sign-in never leaves the sheet.
        if UITestFixture.isActive, providers.connector(for: .dropbox) == nil {
            providers.register(connector: DropboxConnector(appKey: "uitest", secrets: remoteSecrets, returnPort: 0))
        }
        if UITestFixture.isActive, providers.connector(for: .googleDrive) == nil {
            providers.register(connector: GoogleDriveConnector(client: GoogleClient(id: "uitest", secret: "uitest"), secrets: remoteSecrets))
        }
        if UITestFixture.isActive, providers.connector(for: .oneDrive) == nil {
            providers.register(connector: OneDriveConnector(clientID: "uitest", secrets: remoteSecrets))
        }
        #endif
        // Find Files: Automatic asks the index first (added by the window), then walks; Spotlight when chosen.
        let searchEngines = SearchEngines([LiveSearchEngine(), SpotlightSearchEngine()])
        let indexFolder = dataDirectory.appendingPathComponent("Index", isDirectory: true)
        var searchIndex = FilenameIndex.bootVolume(in: indexFolder)
        #if DEBUG
        // UI tests index only the fixture, never the whole disk.
        if UITestFixture.isActive, let root = start?.left {
            searchIndex = FilenameIndex(file: indexFolder.appendingPathComponent("Fixture.basilindex"), root: root.path)
        }
        #endif
        let controller = MainWindowController(providers: providers, commands: commands, settings: settings,
                                              queue: queue, defaults: defaults, startDirectories: start,
                                              dataDirectory: dataDirectory, secrets: secrets,
                                              remoteSecrets: remoteSecrets,
                                              copiesDirectory: copiesDirectory, git: git,
                                              searchEngines: searchEngines, searchIndex: searchIndex)
        // App menu and Edit menu, then the command menus, then Window and Help.
        if let mainMenu = NSApp.mainMenu { controller.installCommandMenus(in: mainMenu, at: 2) }
        #if DEBUG
        if let places = UITestFixture.leftoverPlaces {
            controller.leftoverRoots = .init(home: places.appendingPathComponent("home"),
                                             systemLibrary: places.appendingPathComponent("Library"),
                                             userCache: places.appendingPathComponent("var/C"),
                                             userTemp: places.appendingPathComponent("var/T"),
                                             receipts: places.appendingPathComponent("receipts"))
        }
        #endif
        #if DEBUG
        if UITestFixture.isActive { controller.opensBrowser = false }
        // UI tests: Check for Updates finds a made-up release and never goes online.
        if UITestFixture.isActive {
            let offer = ProcessInfo.processInfo.environment["BASIL_UITEST_UPDATE"] == "1"
            controller.setUpdateSource {
                guard offer else { return nil }
                return AvailableUpdate(version: AppVersion("99.0.0")!, title: "Basil 99.0.0",
                                       notes: "## Added\n- Updates from GitHub releases\n- A new About window",
                                       page: nil, dmg: URL(string: "https://example.invalid/Basil-99.0.0.dmg")!,
                                       dmgName: "Basil-99.0.0.dmg", dmgSize: 1, sha256: nil)
            }
        }
        #endif
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate()
        // Updates from GitHub releases: automatic checks only in Release builds (UI tests and
        // development builds never ask); Basil > Check for Updates... works in every build.
        #if !DEBUG
        controller.startUpdateChecks()
        #endif
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show(settings: settings)
    }

    @objc func showAbout(_ sender: Any?) {
        AboutWindowController.show(checkForUpdates: { [weak self] in self?.mainWindowController?.checkForUpdates() })
    }

    @objc func checkForUpdates(_ sender: Any?) {
        mainWindowController?.performFromMenu("app.checkForUpdates")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.confirmQuitWithEditedCopies() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.removeTemporaryCopies()
        mainWindowController?.saveSearchIndex()
        // An update was installed: open the new version once this process has gone.
        if let app = mainWindowController?.updateToRelaunch { UpdateInstaller.relaunchAfterQuit(app) }
        #if DEBUG
        UITestFixture.cleanup()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// The app, Edit, Window and Help menus. The command menus come from the registry
/// (`MainWindowController.installCommandMenus`).
@MainActor
enum MainMenu {
    static func build(settingsTarget: AnyObject) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Basil")
        appMenu.addItem(withTitle: "About Basil", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
            .target = settingsTarget
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
            .target = settingsTarget
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = settingsTarget
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Basil", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Basil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Text editing in dialogs and settings fields. In the panes, registry keys win
        // (Cmd+A selects all files there).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        // No Cmd+M: that key opens the Multi-Rename tool (Total Commander's Ctrl+M).
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // macOS adds its menu search field here, which also finds every command in the menus.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        return main
    }
}
