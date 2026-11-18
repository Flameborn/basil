import AppKit
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
        var start: (left: VFSPath, right: VFSPath)?
        var defaults = UserDefaults.standard
        #if DEBUG
        start = UITestFixture.makeIfRequested()
        if let isolated = UITestFixture.isolatedDefaults() {
            defaults = isolated
            settings = SettingsStore(defaults: isolated)
        }
        #endif
        let controller = MainWindowController(providers: providers, commands: commands, settings: settings,
                                              queue: queue, defaults: defaults, startDirectories: start)
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

/// Minimal programmatic main menu. Commands will come from CommandRegistry (M1).
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
        appMenu.addItem(withTitle: "Quit Basil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
