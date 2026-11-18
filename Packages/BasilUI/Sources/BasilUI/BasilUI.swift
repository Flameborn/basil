// BasilUI
//
// AppKit panes and main window, plus SwiftUI dialogs and settings.
// See CLAUDE.md for the architecture and progress.md for status.

import AppKit

/// The main dual-pane window. The panes are placeholders until M1.
@MainActor
public final class MainWindowController: NSWindowController {
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Basil"
        window.setFrameAutosaveName("BasilMainWindow")
        window.contentViewController = DualPaneViewController()
        super.init(window: window)
        if !window.setFrameUsingName("BasilMainWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class DualPaneViewController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        for side in PaneSide.allCases {
            let item = NSSplitViewItem(viewController: PanePlaceholderViewController(side: side))
            item.minimumThickness = 240
            addSplitViewItem(item)
        }
    }
}

enum PaneSide: CaseIterable {
    case left, right

    var accessibilityLabel: String {
        switch self {
        case .left: "Left pane"
        case .right: "Right pane"
        }
    }
}

@MainActor
final class PanePlaceholderViewController: NSViewController {
    private let side: PaneSide

    init(side: PaneSide) {
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(side.accessibilityLabel)
        container.setAccessibilityIdentifier(side == .left ? "pane.left" : "pane.right")

        let label = NSTextField(labelWithString: side.accessibilityLabel)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }
}
