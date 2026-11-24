import AppKit
import BasilCore
import SwiftUI
import Synchronization

/// Theme tokens. Every colour used by the UI comes from here; nothing is hard-coded in views.
/// Each token has a light and a dark variant that follows the system appearance.
/// Pairs used together (text on background) are checked for at least 4.5:1 contrast (WCAG AA;
/// `ThemeContrast` in BasilCore lists them); the values are in `ThemeToken.defaults` and user themes.
@MainActor
public enum Theme {
    /// The theme in use. Read by every colour when it is drawn, so a new theme shows at once
    /// (`apply` redraws the windows).
    nonisolated private static let palette = Mutex(ThemeDefinition.builtin)

    nonisolated static func token(_ token: ThemeToken) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: palette.withLock { $0.color(token) }.value(dark: isDark))
        }
    }

    /// Uses `theme` from now on and redraws every window.
    static func apply(_ theme: ThemeDefinition) {
        guard palette.withLock({ $0 }) != theme else { return }
        palette.withLock { $0 = theme }
        for window in NSApp.windows {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            redraw(view)
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        if let table = view as? NSTableView { table.reloadData() }
        for subview in view.subviews { redraw(subview) }
    }

    // Panes
    static let paneBackground = token(.paneBackground)
    static let alternateRow = token(.alternateRow)
    static let text = token(.text)
    static let directoryText = token(.directoryText)
    static let hiddenText = token(.hiddenText)
    static let selectedText = token(.selectedText)
    static let cursorBackground = token(.cursorBackground)
    static let cursorText = token(.cursorText)
    static let cursorSelectedText = token(.cursorSelectedText)
    /// Cursor outline in the inactive pane.
    static let inactiveCursor = token(.inactiveCursor)

    // Path header above each pane
    static let headerActiveBackground = token(.headerActiveBackground)
    static let headerActiveText = token(.headerActiveText)
    static let headerInactiveBackground = token(.headerInactiveBackground)
    static let headerInactiveText = token(.headerInactiveText)

    // Bars (drive bar, status line, function-key bar)
    static let barBackground = token(.barBackground)
    static let barText = token(.barText)
    static let separator = token(.separator)
    static let errorText = token(.errorText)

    /// Secondary text (hints, counts, states) in dialogs, settings and the queue panel. The system's
    /// secondary label colour renders at about 3.5:1 on light window backgrounds. This one is about 8:1
    /// (light) and 5:1 (dark) as specified; small text renders lighter through antialiasing, so keep margin.
    static let secondaryText = token(.secondaryText)
    /// The SwiftUI form of `secondaryText`: the primary label colour at 85 percent (about 9:1 light,
    /// 8:1 dark; 75 percent was flagged "nearly passed" on a wrapped hint). Not `Color(nsColor: secondaryText)`: the accessibility audit misreads SwiftUI text
    /// drawn in a custom dynamic NSColor and reports a contrast failure for it in dark mode.
    static var secondaryTextColor: Color { Color.primary.opacity(0.85) }
    static var errorTextColor: Color { Color(nsColor: errorText) }

    // Compare by Content: row backgrounds for lines or bytes that differ (the Status column says
    // the same in words). Theme.text stays above 10:1 on all of them.
    static let compareChanged = token(.compareChanged)
    static let compareOnlyLeft = token(.compareOnlyLeft)
    static let compareOnlyRight = token(.compareOnlyRight)

    // Progress bars (queue panel). Outline and fill keep at least 3:1 against the window background
    // (WCAG non-text contrast); the track itself is transparent.
    static let progressOutline = token(.progressOutline)
    static let progressFill = token(.progressFill)

    static let listFont = NSFont.systemFont(ofSize: 12)
    static let listBoldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let listDigitsFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let barFont = NSFont.systemFont(ofSize: 11)
    static let rowHeight: CGFloat = 19
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
