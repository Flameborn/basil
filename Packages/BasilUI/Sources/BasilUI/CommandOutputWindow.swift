import AppKit
import BasilIntegrations

/// The output of a command run from a pane's command line. One window per command.
///
/// The window opens once the command prints something, after a second, or when it fails; a
/// command that finishes quickly, silently and successfully only says "Finished". The output is
/// a read-only text view (arrow keys and VoiceOver read it line by line); above it a status line
/// ("Running in Downloads", "Finished, 12 lines", "Failed, exit code 1", "Stopped"), which is
/// spoken when it ends. Stop (Cmd+Period), Run Again, Close (Escape, Cmd+W; stops a running
/// command first).
@MainActor
final class CommandOutputWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: CommandOutputWindowController] = [:]
    /// Text kept per window; older output is dropped beyond it.
    static let outputLimit = 2_000_000

    private let command: String
    private let folder: URL
    private let folderName: String
    private let announce: (String) -> Void
    private let finished: () -> Void
    private var shell: ShellCommand?
    /// The shell from Settings (nil or empty: the login shell).
    private var shellPath: String?
    private var generation = 0
    private var lineCount = 0
    private var trimmed = false
    private var shown = false

    private let statusLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let stopButton = NSButton(title: "Stop Command", target: nil, action: nil)
    private let againButton = NSButton(title: "Run Again", target: nil, action: nil)

    static func run(_ command: String, in folder: URL, folderName: String, shell: String? = nil,
                    announce: @escaping (String) -> Void, finished: @escaping () -> Void) {
        let controller = CommandOutputWindowController(command: command, folder: folder, folderName: folderName,
                                                       announce: announce, finished: finished)
        controller.shellPath = shell
        open[ObjectIdentifier(controller)] = controller
        controller.start()
    }

    private init(command: String, folder: URL, folderName: String,
                 announce: @escaping (String) -> Void, finished: @escaping () -> Void) {
        self.command = command
        self.folder = folder
        self.folderName = folderName
        self.announce = announce
        self.finished = finished
        let window = CommandOutputNSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                           backing: .buffered, defer: false)
        let short = command.count > 60 ? String(command.prefix(57)) + "..." : command
        window.title = short
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        window.delegate = self
        window.onStop = { [weak self] in self?.stopCommand() }
        buildContent(in: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in window: NSWindow) {
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("commandOutput.status")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = Theme.text
        textView.backgroundColor = Theme.paneBackground
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Output")
        textView.setAccessibilityIdentifier("commandOutput.text")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stopButton.bezelStyle = .push
        stopButton.target = self
        stopButton.action = #selector(stopCommand)
        stopButton.toolTip = "Cmd+Period"
        againButton.bezelStyle = .push
        againButton.target = self
        againButton.action = #selector(runAgain)
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .push
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [stopButton, againButton, spacer, close])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = ThemedBox()
        root.fillColor = Theme.barBackground
        statusLabel.textColor = Theme.barText
        for v in [statusLabel, scroll, buttons] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window.contentView = root
        window.initialFirstResponder = textView
    }

    // MARK: Running

    private func start() {
        generation += 1
        let current = generation
        textView.string = ""
        lineCount = 0
        trimmed = false
        setStatus("Running in \(folderName)")
        stopButton.isEnabled = true
        againButton.isEnabled = false
        let shell = ShellCommand(command, in: folder, shell: shellPath)
        self.shell = shell
        do {
            try shell.start(output: { [weak self] text in
                guard let self, current == generation else { return }
                append(text)
            }, finished: { [weak self] outcome in
                guard let self, current == generation else { return }
                end(outcome)
            })
        } catch {
            self.shell = nil
            stopButton.isEnabled = false
            againButton.isEnabled = true
            append("Could not start \(shell.shell): \(error.localizedDescription)\n")
            setStatus("Failed to start")
            showWindow()
            announce("Failed to start")
            return
        }
        // Long-running commands that print nothing yet still get their window.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, current == generation, self.shell?.isRunning == true else { return }
            showWindow()
        }
    }

    private func append(_ text: String) {
        lineCount += text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let storage = textView.textStorage!
        let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 4
        storage.append(NSAttributedString(string: text, attributes: [
            .font: textView.font as Any, .foregroundColor: Theme.text,
        ]))
        if storage.length > Self.outputLimit {
            let excess = storage.length - Self.outputLimit
            let cut = (storage.string as NSString).range(of: "\n", range: NSRange(location: excess, length: storage.length - excess))
            storage.deleteCharacters(in: NSRange(location: 0, length: cut.location == NSNotFound ? excess : cut.location + 1))
            trimmed = true
        }
        if atEnd || !shown { textView.scrollToEndOfDocument(nil) }
        showWindow()
    }

    private func end(_ outcome: ShellCommand.Outcome) {
        shell = nil
        stopButton.isEnabled = false
        againButton.isEnabled = true
        let hasOutput = !textView.string.isEmpty
        let lines = !hasOutput ? "no output" : lineCount <= 1 ? "1 line" : "\(lineCount) lines"
        let message: String
        switch outcome {
        case .exited(0): message = "Finished, \(lines)"
        case .exited(let code): message = "Failed, exit code \(code), \(lines)"
        case .stopped: message = "Stopped"
        }
        setStatus(message + (trimmed ? ". Earlier output was dropped" : ""))
        finished()
        if !shown, outcome == .exited(0), !hasOutput {
            // Quick and silent: no window, just the result (focus stays in the pane).
            announce("Finished")
            Self.open[ObjectIdentifier(self)] = nil
            return
        }
        showWindow()
        announce(message)
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.setAccessibilityLabel(text)
    }

    private func showWindow() {
        guard !shown, let window else { return }
        shown = true
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    @objc private func stopCommand() {
        guard let shell, shell.isRunning else { return }
        setStatus("Stopping")
        shell.stop()
    }

    @objc private func runAgain() {
        guard shell == nil else { return }
        start()
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        shell?.stop()
        shell = nil
        Self.open[ObjectIdentifier(self)] = nil
    }
}

/// Escape and Cmd+W close the window; Cmd+Period stops the command.
final class CommandOutputNSWindow: NSWindow {
    var onStop: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { performClose(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "." {
            onStop?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
