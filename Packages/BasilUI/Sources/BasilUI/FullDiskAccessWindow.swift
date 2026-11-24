import AppKit
import BasilIntegrations

/// Shown at launch while Basil lacks Full Disk Access: what it is for, how to grant it, the
/// current status, and Quit / Open System Settings / Continue. Continue stays disabled until
/// the status says granted; the window cannot be closed any other way than Quit or Continue.
/// The status is checked every second and whenever Basil comes to the front, so Continue is
/// enabled (and that is spoken) the moment access is granted in System Settings.
@MainActor
public final class FullDiskAccessWindowController: NSWindowController {
    private static var shared: FullDiskAccessWindowController?

    /// Shows the window when `check` does not allow continuing and calls `onContinue` once the
    /// user chooses Continue; calls it at once when access is already there.
    public static func runIfNeeded(check: @escaping @MainActor () -> FullDiskAccess.Status = { FullDiskAccess.status() },
                                   onContinue: @escaping @MainActor () -> Void) {
        guard !check().allowsContinuing else {
            onContinue()
            return
        }
        let controller = FullDiskAccessWindowController(check: check, onContinue: onContinue)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private init(check: @escaping @MainActor () -> FullDiskAccess.Status, onContinue: @escaping @MainActor () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Full Disk Access"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = FullDiskAccessViewController(check: check) { [weak self] in
            // The main window first: closing the last window would quit Basil.
            onContinue()
            self?.window?.close()
            FullDiskAccessWindowController.shared = nil
        }
        window.contentViewController = content
        window.initialFirstResponder = content.initialFocus
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class FullDiskAccessViewController: NSViewController {
    private let check: @MainActor () -> FullDiskAccess.Status
    private let onContinue: @MainActor () -> Void
    private let statusLabel = NSTextField(labelWithString: "")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private var timer: Timer?
    private var status: FullDiskAccess.Status?
    private var activeObserver: (any NSObjectProtocol)?

    var initialFocus: NSView { settingsButton }

    init(check: @escaping @MainActor () -> FullDiskAccess.Status, onContinue: @escaping @MainActor () -> Void) {
        self.check = check
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.accessibilityDescription = "Basil app icon"
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64),
                                     icon.heightAnchor.constraint(equalToConstant: 64)])

        let heading = Self.label("Basil needs Full Disk Access to continue", font: .systemFont(ofSize: 17, weight: .semibold))
        heading.setAccessibilityRole(.staticText)
        let why = Self.label("A file manager has to see and change files in every folder, including the ones macOS protects: "
            + "Mail, Messages, Safari, Time Machine backups and other apps' data. Without Full Disk Access those "
            + "folders look empty or cannot be opened, and copies from them fail.",
            font: .systemFont(ofSize: NSFont.systemFontSize))
        let steps = Self.label("1. Choose Open System Settings. It opens Privacy and Security, Full Disk Access.\n"
            + "2. Turn on Basil in the list. If Basil is not listed, choose the Add button below the list and select "
            + "Basil at \(Bundle.main.bundlePath).\n"
            + "3. Come back here. Continue becomes available as soon as access is granted.",
            font: .systemFont(ofSize: NSFont.systemFontSize))

        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        statusLabel.setAccessibilityIdentifier("fullDiskAccess.status")

        let quit = NSButton(title: "Quit Basil", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .push
        settingsButton.bezelStyle = .push
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        continueButton.bezelStyle = .push
        continueButton.target = self
        continueButton.action = #selector(continuePressed)
        continueButton.setAccessibilityHelp("Available once Full Disk Access is granted")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [quit, spacer, settingsButton, continueButton])
        buttons.spacing = 10

        let top = NSStackView(views: [icon, heading])
        top.spacing = 14
        top.alignment = .centerY

        let stack = NSStackView(views: [top, why, steps, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(20, after: statusLabel)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for text in [why, steps] { text.preferredMaxLayoutWidth = 472 }

        let root = ThemedBox()
        root.fillColor = Theme.paneBackground
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes: also while a menu is open or the window is being moved.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    private func refresh() {
        let new = check()
        guard new != status else { return }
        let first = status == nil
        status = new
        switch new {
        case .granted:
            statusLabel.stringValue = "Status: granted"
            statusLabel.textColor = Theme.text
        case .notGranted:
            statusLabel.stringValue = "Status: not granted"
            statusLabel.textColor = Theme.errorText
        case .unknown:
            statusLabel.stringValue = "Status: could not be checked"
            statusLabel.textColor = Theme.text
        }
        continueButton.isEnabled = new.allowsContinuing
        continueButton.keyEquivalent = new.allowsContinuing ? "\r" : ""
        guard !first else { return }
        if new.allowsContinuing {
            announce(new == .granted ? "Full Disk Access granted. Continue is available." : statusLabel.stringValue)
            // Back in Basil, Return continues.
            view.window?.makeFirstResponder(continueButton)
        } else {
            announce("Full Disk Access is not granted")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func openSettings() { FullDiskAccess.openSettings() }

    @objc private func continuePressed() {
        // Checked again: the button only reflects the last tick.
        refresh()
        guard status?.allowsContinuing == true else { return }
        stop()
        onContinue()
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = Theme.text
        field.isSelectable = false
        return field
    }
}
