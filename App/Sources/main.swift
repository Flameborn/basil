import AppKit
import BasilGit

// Started by git or ssh as their askpass program: answer through the running Basil and exit
// (no window, no app).
GitAskPass.runIfRequested()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
