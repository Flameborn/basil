import AppKit
import BasilCore
import BasilIntegrations

/// Updates from GitHub releases (`AppUpdater.swift` in BasilIntegrations): a check at launch
/// and once a day while Basil runs (setting "Check for updates automatically"), and
/// Basil > Check for Updates... (`app.checkForUpdates`). A new version is offered in a sheet
/// with its release notes: Install and Relaunch, Skip This Version, Remind Me Later.
@MainActor
final class UpdateCoordinator {
    private weak var window: MainWindowController?
    private let feed: UpdateFeed
    private var timer: Timer?
    private var lastCheck: Date?
    private var busy = false
    /// The version offered in this run with Remind Me Later: automatic checks stay quiet about it
    /// until Basil starts again.
    private var postponed: AppVersion?
    /// Set when an update was installed and Basil is quitting to start it.
    private(set) var relaunchApp: URL?

    /// Where the latest release comes from: GitHub, or a fixed answer in UI tests.
    var source: @Sendable () async throws -> AvailableUpdate?

    init(window: MainWindowController, feed: UpdateFeed = .basil) {
        self.window = window
        self.feed = feed
        source = { try await feed.latest() }
    }

    /// Automatic checks: once a few seconds after launch, then whenever a day has passed.
    func startAutomaticChecks() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.automaticCheck()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let last = self.lastCheck, Date().timeIntervalSince(last) >= 24 * 3600 else { return }
                self.automaticCheck()
            }
        }
    }

    private func automaticCheck() {
        guard let window, window.settings.settings.checkForUpdates else { return }
        Task { await check(interactive: false) }
    }

    /// Basil > Check for Updates...: also says when there is nothing new or the check failed,
    /// and offers a version that was skipped.
    func checkNow() {
        Task { await check(interactive: true) }
    }

    private func check(interactive: Bool) async {
        guard !busy, let window else {
            if interactive { window?.announce("Already checking for updates") }
            return
        }
        busy = true
        defer { busy = false }
        lastCheck = Date()
        guard let current = AppVersion.running else { return }
        if interactive { window.announce("Checking for updates") }
        let update: AvailableUpdate?
        do {
            update = try await source()
        } catch {
            if interactive {
                await window.updateAlert(title: "Basil could not check for updates.",
                                         text: error.localizedDescription, page: nil)
            }
            return
        }
        guard let update, update.version > current else {
            if interactive {
                await window.updateAlert(title: "Basil is up to date.",
                                         text: "Basil \(current) is the newest version.", page: nil)
            }
            return
        }
        if !interactive {
            if window.settings.settings.skippedUpdateVersion.flatMap(AppVersion.init) == update.version { return }
            if postponed == update.version { return }
        }
        switch await window.offerUpdate(update, current: current) {
        case .install:
            await install(update)
        case .skip:
            window.settings.settings.skippedUpdateVersion = update.version.description
        case .later:
            postponed = update.version
        }
    }

    private func install(_ update: AvailableUpdate) async {
        guard let window else { return }
        // Relaunching stops what the queue is doing, so the update waits for it.
        if window.queue.items.contains(where: { !$0.state.isDone }) {
            guard await window.confirmWaitForQueue() else { return }
            window.announce("The update starts when the queue is done")
            while window.queue.items.contains(where: { !$0.state.isDone }) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let installer = UpdateInstaller()
        let sheet = UpdateProgressSheet(title: "Updating to Basil \(update.version)")
        let task = Task.detached { () -> URL in
            let dmg = try await installer.download(update) { fraction in
                Task { @MainActor in sheet.setProgress(fraction) }
            }
            try Task.checkCancellation()
            await MainActor.run { sheet.setInstalling() }
            let staged = try installer.stage(dmg, version: update.version)
            try installer.install(staged)
            return installer.installedApp
        }
        sheet.onCancel = { task.cancel() }
        window.showProgressSheet(sheet)
        window.announce("Downloading Basil \(update.version)")
        let result = await task.result
        window.closeProgressSheet(sheet)
        switch result {
        case .success(let app):
            relaunchApp = app
            window.announce("Basil \(update.version) is installed. Relaunching")
            NSApp.terminate(nil)
            // Still here: quitting was cancelled (for example edited archive copies).
            relaunchApp = nil
            window.announce("Basil \(update.version) is installed and starts the next time Basil opens")
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                window.announce("Update cancelled")
                return
            }
            await window.updateAlert(title: "The update could not be installed.",
                                     text: error.localizedDescription, page: update.page)
        }
    }
}

enum UpdateChoice { case install, skip, later }

extension MainWindowController {
    /// Starts the automatic checks (AppDelegate; not in Debug builds or UI tests).
    public func startUpdateChecks() { updates.startAutomaticChecks() }

    /// Basil > Check for Updates..., and Check Now in Settings.
    public func checkForUpdates() { updates.checkNow() }

    /// Replaces the GitHub lookup (UI tests offer a made-up release this way).
    public func setUpdateSource(_ source: @escaping @Sendable () async throws -> AvailableUpdate?) {
        updates.source = source
    }

    /// The installed update to open once Basil has quit (AppDelegate.applicationWillTerminate).
    public var updateToRelaunch: URL? { updates.relaunchApp }

    /// The sheet that offers a new version, with the release's notes (the changelog entries).
    func offerUpdate(_ update: AvailableUpdate, current: AppVersion) async -> UpdateChoice {
        guard let window else { return .later }
        while window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(300)) }
        let alert = NSAlert()
        alert.messageText = "Basil \(update.version) is available"
        alert.informativeText = "You have Basil \(current). Basil downloads the new version from GitHub, checks it and relaunches."
        let notes = update.plainNotes
        if !notes.isEmpty { alert.accessoryView = Self.releaseNotesView(notes) }
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Skip This Version")
        let later = alert.addButton(withTitle: "Remind Me Later")
        later.keyEquivalent = "\u{1b}"
        return switch await present(alert, in: window) {
        case 0: .install
        case 1: .skip
        default: .later
        }
    }

    /// A read-only, scrollable text view labelled "What's new".
    private static func releaseNotesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textColor = .labelColor
        text.string = notes
        text.setAccessibilityLabel("What's new")
        scroll.documentView = text
        return scroll
    }

    func confirmWaitForQueue() async -> Bool {
        guard let window else { return false }
        let count = queue.items.filter { !$0.state.isDone }.count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 operation is still in the queue." : "\(count) operations are still in the queue."
        alert.informativeText = "Basil installs the update and relaunches once the queue is done."
        alert.addButton(withTitle: "Install When Done")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return await present(alert, in: window) == 0
    }

    /// A message with OK, and Open Release Page when a page is given.
    func updateAlert(title: String, text: String, page: URL?) async {
        guard let window else { return }
        while window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(300)) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if page != nil { alert.addButton(withTitle: "Open Release Page") }
        if await present(alert, in: window) == 1, let page { NSWorkspace.shared.open(page) }
    }

    func showProgressSheet(_ sheet: UpdateProgressSheet) {
        guard let window else { return }
        window.beginSheet(sheet.window)
    }

    func closeProgressSheet(_ sheet: UpdateProgressSheet) {
        guard let window else { return }
        window.endSheet(sheet.window)
        window.makeFirstResponder(activePane.tableView)
    }
}

/// Download and install progress: a label, a bar and Cancel (Escape).
@MainActor
final class UpdateProgressSheet {
    let window: EscapableSheet
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?
    private let title: String

    init(title: String) {
        self.title = title
        window = EscapableSheet(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        label.stringValue = "Downloading"
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityLabel(title)
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 380),
        ])
        stack.setCustomSpacing(16, after: bar)
        window.contentView = content
        window.onCancel = { [weak self] in self?.cancelPressed() }
        window.initialFirstResponder = cancel
    }

    func setProgress(_ fraction: Double) {
        bar.doubleValue = fraction
        let percent = Int((fraction * 100).rounded(.down))
        label.stringValue = "Downloading, \(percent) percent"
        bar.setAccessibilityValue("\(percent) percent")
    }

    func setInstalling() {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        label.stringValue = "Checking and installing"
        cancel.isEnabled = false
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Checking and installing", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func cancelPressed() {
        guard cancel.isEnabled else { return }
        cancel.isEnabled = false
        label.stringValue = "Cancelling"
        onCancel?()
    }
}
