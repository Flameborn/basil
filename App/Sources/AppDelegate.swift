import AppKit
import BasilArchives
import BasilCore
import BasilOperations
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
        var start: (left: VFSPath, right: VFSPath)?
        var defaults = UserDefaults.standard
        var dataDirectory = MainWindowController.defaultDataDirectory
        var secrets: any SecretStore = Keychain.archivePasswords
        #if DEBUG
        start = UITestFixture.makeIfRequested()
        if let isolated = UITestFixture.isolatedDefaults() {
            defaults = isolated
            BasilWindows.savesFrames = false
            dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("basil-uitest-data", isDirectory: true)
            try? FileManager.default.removeItem(at: dataDirectory)
            settings = SettingsStore(defaults: isolated)
            secrets = MemorySecretStore() // UI tests never touch the user's keychain
            // UI tests run silently (no sounds, no system voice).
            for outcome in QueueOutcome.allCases {
                settings.settings.feedback.defaults[outcome.rawValue] = EventFeedback(sound: .none, speak: false, text: "")
            }
        }
        #endif
        let controller = MainWindowController(providers: providers, commands: commands, settings: settings,
                                              queue: queue, defaults: defaults, startDirectories: start,
                                              dataDirectory: dataDirectory, secrets: secrets)
        // App menu and Edit menu, then the command menus, then Window and Help.
        if let mainMenu = NSApp.mainMenu { controller.installCommandMenus(in: mainMenu, at: 2) }
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show(settings: settings)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        appMenu.addItem(withTitle: "About Basil",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
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
