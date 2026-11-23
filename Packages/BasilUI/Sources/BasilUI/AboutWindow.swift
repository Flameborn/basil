import AppKit

/// Basil > About Basil: the app icon, name, version, developer, the GitHub page, the license
/// (the LICENSE file bundled in the app) and the libraries Basil is built with.
@MainActor
public final class AboutWindowController: NSWindowController {
    private static var shared: AboutWindowController?
    public static let repository = URL(string: "https://github.com/Flameborn/basil")!

    public static func show(checkForUpdates: (() -> Void)?) {
        let controller = shared ?? AboutWindowController(checkForUpdates: checkForUpdates)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(checkForUpdates: (() -> Void)?) {
        let window = AboutNSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Basil"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = AboutViewController(info: .current, checkForUpdates: checkForUpdates)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Escape and Cmd+W close the About window (the main menu has no Close item).
final class AboutNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w", attachedSheet == nil {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct AboutInfo {
    var version: String
    var build: String
    var license: String

    static var current: AboutInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "MIT License. Copyright (c) 2026 Flameborn. The full text is in the LICENSE file on GitHub."
        return AboutInfo(version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                         build: info["CFBundleVersion"] as? String ?? "unknown",
                         license: license)
    }
}

/// The open source code Basil includes or links, with its license.
struct Acknowledgement {
    var name: String
    var license: String

    static let all: [Acknowledgement] = [
        .init(name: "7-Zip by Igor Pavlov", license: "GNU LGPL 2.1 or later, with the unRAR restriction"),
        .init(name: "BLAKE3", license: "CC0 1.0 or Apache License 2.0"),
        .init(name: "libarchive", license: "BSD 2-Clause License"),
        .init(name: "libssh2", license: "BSD 3-Clause License"),
        .init(name: "LZ4", license: "BSD 2-Clause License"),
        .init(name: "OpenSSL", license: "Apache License 2.0"),
        .init(name: "SwiftyDropbox", license: "MIT License"),
        .init(name: "UnRAR by Alexander Roshal", license: "UnRAR license (freeware)"),
        .init(name: "XZ Utils (liblzma)", license: "BSD Zero Clause License"),
        .init(name: "xxHash", license: "BSD 2-Clause License"),
        .init(name: "Zstandard", license: "BSD License"),
    ]
}

/// The About window's content: icon, name, version, description, developer, copyright, buttons.
@MainActor
final class AboutViewController: NSViewController {
    private let info: AboutInfo
    private let checkForUpdates: (() -> Void)?

    init(info: AboutInfo, checkForUpdates: (() -> Void)?) {
        self.info = info
        self.checkForUpdates = checkForUpdates
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        // Icon Services renders the Icon Composer icon; NSApp.applicationIconImage can be a placeholder.
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.accessibilityDescription = "Basil app icon"
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Basil app icon")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 128),
                                     icon.heightAnchor.constraint(equalToConstant: 128)])

        let name = Self.label("Basil", font: .systemFont(ofSize: 26, weight: .semibold))
        name.setAccessibilityRole(.staticText)
        let version = Self.label("Version \(info.version) (build \(info.build))", font: .systemFont(ofSize: NSFont.systemFontSize),
                                 color: Theme.secondaryText)
        let tagline = Self.label("A dual-pane file manager for macOS, in the spirit of Total Commander.",
                                 font: .systemFont(ofSize: NSFont.systemFontSize))
        let developer = Self.label("Developed by Flameborn", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium))
        let copyright = Self.label("Copyright 2026 Flameborn. Free and open source under the MIT License.",
                                   font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: Theme.secondaryText)

        let github = Self.button("GitHub Page", target: self, action: #selector(openGitHub))
        let license = Self.button("License", target: self, action: #selector(showLicense))
        let thanks = Self.button("Acknowledgements", target: self, action: #selector(showAcknowledgements))
        var lower: [NSView] = []
        if checkForUpdates != nil { lower.append(Self.button("Check for Updates...", target: self, action: #selector(runCheck))) }
        let close = Self.button("Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        lower.append(close)

        let links = NSStackView(views: [github, license, thanks])
        links.spacing = 10
        let actions = NSStackView(views: lower)
        actions.spacing = 10

        let stack = NSStackView(views: [icon, name, version, tagline, developer, copyright, links, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(14, after: version)
        stack.setCustomSpacing(14, after: tagline)
        stack.setCustomSpacing(18, after: copyright)
        stack.setCustomSpacing(10, after: links)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for text in [tagline, copyright] {
            text.preferredMaxLayoutWidth = 404
        }
        // Theme colours, like the panes.
        let root = ThemedBox()
        root.fillColor = Theme.paneBackground
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        view = root
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = Theme.text) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.isSelectable = false
        return field
    }

    private static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        return button
    }

    @objc private func openGitHub() { NSWorkspace.shared.open(AboutWindowController.repository) }
    @objc private func runCheck() { checkForUpdates?() }
    @objc private func closeWindow() { view.window?.performClose(nil) }

    @objc private func endTextSheet() {
        guard let window = view.window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
    }

    @objc private func showLicense() {
        showText(title: "License", intro: "Basil is free and open source software under the MIT License.",
                 text: Self.reflowed(info.license))
    }

    /// LICENSE breaks its lines at 80 characters; joined into paragraphs so the sheet wraps them.
    static func reflowed(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    @objc private func showAcknowledgements() {
        let lines = Acknowledgement.all.map { "\($0.name): \($0.license)" }
        showText(title: "Acknowledgements",
                 intro: "Basil is built with these open source projects. Their license texts are in the Vendor folder of the source code.",
                 text: lines.joined(separator: "\n"))
    }

    /// A sheet with a scrolling, read-only text and Done (Return or Escape).
    private func showText(title: String, intro: String, text: String) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let sheet = EscapableSheet(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = title
        let heading = Self.label(title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold))
        heading.alignment = .left
        let introLabel = Self.label(intro, font: .systemFont(ofSize: NSFont.systemFontSize))
        introLabel.alignment = .left
        introLabel.preferredMaxLayoutWidth = 480

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = Theme.text
        textView.string = text
        textView.setAccessibilityLabel(title)
        scroll.documentView = textView

        let done = Self.button("Done", target: self, action: #selector(endTextSheet))
        done.keyEquivalent = "\r"
        sheet.onCancel = { [weak self] in self?.endTextSheet() }

        let buttons = NSStackView(views: [done])
        let stack = NSStackView(views: [heading, introLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = ThemedBox()
        root.fillColor = Theme.paneBackground
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 480),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
        ])
        sheet.contentView = root
        sheet.initialFirstResponder = textView
        window.beginSheet(sheet)
    }
}
