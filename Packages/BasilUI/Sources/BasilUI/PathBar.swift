import AppKit
import BasilCore
import BasilVFS

/// The path header of a pane: one button per path part ("Macintosh HD", "Users", "erion",
/// "Downloads"), like ForkLift. Clicking a part, VO+Space on it, or Return / Space after Cmd+L
/// goes to that folder, which also works when the current folder was deleted.
///
/// The bar is a group labelled "Path" whose value is the whole path. Keyboard: Cmd+L focuses the
/// last part, Left and Right move between parts, Return or Space go there, Escape or Tab go back
/// to the list. The parts sit in a scroll view, so long paths keep every part reachable.
@MainActor
final class PathBar: ThemedBox {
    struct Segment: Equatable, Sendable {
        let title: String
        let path: VFSPath
    }

    var onSelect: ((Segment, _ next: Segment?) -> Void)?
    /// Escape or Tab: back to the list.
    var onLeave: (() -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var segments: [Segment] = []
    private var buttons: [PathSegmentButton] = []
    var isActive = false { didSet { restyle() } }

    init(identifier: String) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityElement(false)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ directory: VFSPath) {
        setAccessibilityValue(directory.description)
        let new = Self.segments(of: directory)
        guard new != segments else { return restyle() }
        segments = new
        let hadFocus = buttons.contains { window?.firstResponder === $0 }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                stack.addArrangedSubview(PathSeparator())
            }
            let button = PathSegmentButton(title: segment.title, target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.bar = self
            button.setAccessibilityLabel(segment.title)
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        restyle()
        layoutSubtreeIfNeeded()
        // Show the end of the path (the current folder) when it does not fit.
        let overflow = stack.fittingSize.width - scroll.contentView.bounds.width
        scroll.contentView.scroll(to: NSPoint(x: max(0, overflow), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        if hadFocus { focusLast() }
    }

    /// Cmd+L: focus on the current folder's part.
    func focusLast() {
        guard let last = buttons.last else { return }
        window?.makeFirstResponder(last)
    }

    fileprivate func move(from button: PathSegmentButton, by offset: Int) {
        let index = button.tag + offset
        guard buttons.indices.contains(index) else { return NSSound.beep() }
        window?.makeFirstResponder(buttons[index])
        buttons[index].scrollToVisible(buttons[index].bounds)
    }

    fileprivate func leave() { onLeave?() }

    @objc private func clicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        let next = segments.indices.contains(sender.tag + 1) ? segments[sender.tag + 1] : nil
        onSelect?(segments[sender.tag], next)
    }

    private func restyle() {
        fillColor = isActive ? Theme.headerActiveBackground : Theme.headerInactiveBackground
        let color = isActive ? Theme.headerActiveText : Theme.headerInactiveText
        for view in stack.arrangedSubviews {
            if let button = view as? NSButton {
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .font: Theme.barFont, .foregroundColor: color,
                ])
            } else if let separator = view as? PathSeparator {
                separator.color = color
            }
        }
    }

    /// The parts of a path. A local path starts with its volume ("Macintosh HD", or the volume
    /// under /Volumes); inside an archive the parts go through the archive's own folders, then
    /// the archive, then the folders inside it. Search results come after the folder searched.
    nonisolated static func segments(of directory: VFSPath) -> [Segment] {
        var result: [Segment] = []
        var root = VFSPath(location: directory.location, path: "/")
        if let listing = Listings.info(directory.location) {
            // Search results: the folder searched, then the results.
            return segments(of: listing.origin) + [Segment(title: listing.title, path: root)]
        }
        if let container = directory.location.container {
            result = segments(of: container.parent ?? container)
            result.append(Segment(title: container.name, path: root))
        } else if directory.location == .local {
            let volume = localVolume(containing: directory.path)
            root = .local(volume.path)
            result.append(Segment(title: volume.name, path: root))
        } else {
            let instance = directory.location.instance
            result.append(Segment(title: instance.isEmpty ? directory.location.provider.rawValue : instance, path: root))
        }
        var current = root
        let skip = root.components.count
        for component in directory.components.dropFirst(skip) {
            current = current.appending(component)
            result.append(Segment(title: component, path: current))
        }
        return result
    }

    /// The mounted volume holding `path` (its root path and name). Falls back to "/".
    nonisolated private static func localVolume(containing path: String) -> (path: String, name: String) {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                         options: []) ?? []
        var best = (path: "/", name: rootVolumeName)
        for url in urls where url.path != "/" {
            let root = url.path
            if path == root || path.hasPrefix(root + "/"), root.count > best.path.count {
                let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
                best = (root, name ?? url.lastPathComponent)
            }
        }
        return best
    }

    nonisolated private static let rootVolumeName: String = {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "/"
    }()
}

/// A path part. Takes keyboard focus (also without Full Keyboard Access) so Cmd+L and the arrow
/// keys work, and VoiceOver follows the focus.
@MainActor
final class PathSegmentButton: NSButton {
    weak var bar: PathBar?

    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        font = Theme.barFont
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let key = Int(event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0)
        switch key {
        case NSLeftArrowFunctionKey where plain: bar?.move(from: self, by: -1)
        case NSRightArrowFunctionKey where plain: bar?.move(from: self, by: 1)
        case 0x0D where plain, 0x03 where plain, 0x20 where plain: performClick(nil)
        case 0x1B, 0x09, 0x19: bar?.leave()
        default: super.keyDown(with: event)
        }
    }
}

/// The slash between two path parts, drawn as a line: not text, so VoiceOver and the
/// accessibility audit never see it.
@MainActor
final class PathSeparator: NSView {
    var color: NSColor = Theme.headerActiveText { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.2
        line.move(to: NSPoint(x: bounds.midX - 2, y: bounds.midY - 5))
        line.line(to: NSPoint(x: bounds.midX + 2, y: bounds.midY + 5))
        line.stroke()
    }
}
