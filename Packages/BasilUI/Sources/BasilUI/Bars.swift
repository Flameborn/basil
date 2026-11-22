import AppKit
import BasilCore

/// A plain view filled with a theme colour (drawn, so it follows light/dark changes automatically).
class ThemedBox: NSView {
    var fillColor: NSColor = Theme.barBackground { didSet { needsDisplay = true } }
    var bottomBorder = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        if bottomBorder {
            Theme.separator.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

// MARK: - Quick filter bar (Cmd+S)

/// The pop-up edit field for the quick filter. Filters live while typing.
/// Return keeps the filter and returns to the list; Esc clears it.
@MainActor
final class QuickFilterBar: ThemedBox, NSSearchFieldDelegate {
    var onChange: ((String, Bool) -> Void)?
    /// Called with `cleared == true` on Esc, false on Return.
    var onFinish: ((Bool) -> Void)?

    private let field = NSSearchField()
    private let regexToggle = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    var isInvalid = false {
        didSet {
            countLabel.stringValue = isInvalid ? "Invalid regex" : countLabel.stringValue
            countLabel.textColor = isInvalid ? Theme.errorText : Theme.barText
        }
    }

    var matchCount: Int? {
        didSet {
            guard !isInvalid else { return }
            countLabel.stringValue = matchCount.map { "\($0) shown" } ?? ""
        }
    }

    var isEditing: Bool { window?.firstResponder == field.currentEditor() && !isHidden }

    init() {
        super.init(frame: .zero)
        fillColor = Theme.barBackground

        let label = NSTextField(labelWithString: "Filter:")
        label.font = Theme.barFont
        label.textColor = Theme.barText
        label.setAccessibilityElement(false)

        field.placeholderString = "Part of a name, or *.mp3;*.flac | *.tmp"
        field.font = Theme.barFont
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Quick filter")
        field.setAccessibilityHelp("Type part of a name or wildcards. Separate patterns with semicolons, exclusions after a bar. Return keeps the filter, Escape clears it.")
        field.setAccessibilityIdentifier("quickFilter.field")
        field.target = self
        field.action = #selector(textChanged)

        regexToggle.font = Theme.barFont
        regexToggle.target = self
        regexToggle.action = #selector(textChanged)
        regexToggle.setAccessibilityLabel("Regular expression mode")

        countLabel.font = Theme.barFont
        countLabel.textColor = Theme.barText

        let stack = NSStackView(views: [label, field, regexToggle, countLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quick filter")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func reset() {
        field.stringValue = ""
        isInvalid = false
        matchCount = nil
    }

    @objc private func textChanged() {
        onChange?(field.stringValue, regexToggle.state == .on)
    }

    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onFinish?(true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onFinish?(false)
            return true
        default:
            return false
        }
    }
}

// MARK: - Drive bar

/// Buttons for Home and mounted volumes, like Total Commander's drive bar.
@MainActor
final class DriveBar: ThemedBox {
    enum Target { case home, volume(URL) }

    struct Volume {
        let name: String
        let url: URL
        let icon: NSImage?
    }

    var onSelect: ((Target) -> Void)?
    private let stack = NSStackView()
    private var observers: [NSObjectProtocol] = []
    private var targets: [Target] = []

    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .effectiveIconKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let icon = (values?.effectiveIcon as? NSImage).map { image -> NSImage in
                let copy = image.copy() as! NSImage
                copy.size = NSSize(width: 14, height: 14)
                return copy
            }
            return Volume(name: values?.volumeLocalizedName ?? url.lastPathComponent, url: url, icon: icon)
        }
    }

    init(side: PaneSide) {
        super.init(frame: .zero)
        fillColor = Theme.barBackground
        bottomBorder = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(side.accessibilityLabel) volumes")

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = [.home]
        addButton(title: "Home", image: nil)
        for volume in Self.volumes() {
            targets.append(.volume(volume.url))
            addButton(title: volume.name, image: volume.icon)
        }
    }

    private func addButton(title: String, image: NSImage?) {
        let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = Theme.barFont
        button.refusesFirstResponder = true
        if let image {
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.tag = stack.arrangedSubviews.count
        button.setAccessibilityLabel(title)
        stack.addArrangedSubview(button)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard targets.indices.contains(sender.tag) else { return }
        onSelect?(targets[sender.tag])
    }
}

// MARK: - Function key bar

/// Bottom bar with one button per function-key command (F3 View ... F8 Delete).
/// Buttons show the current binding and disable themselves when the command is unavailable.
@MainActor
final class FunctionKeyBar: ThemedBox {
    private let stack = NSStackView()
    private var buttons: [(CommandID, NSButton)] = []
    var onInvoke: ((CommandID) -> Void)?

    init(commands: CommandRegistry, ids: [CommandID]) {
        super.init(frame: .zero)
        fillColor = Theme.barBackground
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Function keys")
        setAccessibilityIdentifier("functionKeyBar")

        for id in ids {
            guard let command = commands.command(id) else { continue }
            let chord = commands.primaryChord(for: id)?.description ?? ""
            let button = NSButton(title: "\(chord) \(command.title)", target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.font = Theme.barFont
            button.refusesFirstResponder = true
            button.setAccessibilityLabel(command.title)
            button.setAccessibilityHelp(chord.isEmpty ? nil : "Keyboard shortcut \(chord)")
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            stack.addArrangedSubview(button)
            buttons.append((id, button))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateEnabled(_ isEnabled: (CommandID) -> Bool) {
        for (id, button) in buttons { button.isEnabled = isEnabled(id) }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        onInvoke?(CommandID(rawValue: raw))
    }
}
