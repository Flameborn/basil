import AppKit
import SwiftUI

/// Theme tokens. Every colour used by the UI comes from here; nothing is hard-coded in views.
/// Each token has a light and a dark variant that follows the system appearance.
/// Pairs used together (text on background) are chosen for at least 4.5:1 contrast (WCAG AA).
@MainActor
public enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    // Panes
    static let paneBackground = dynamic(light: 0xFFFFFF, dark: 0x1E1F22)
    static let alternateRow = dynamic(light: 0xF4F6F9, dark: 0x24262A)
    static let text = dynamic(light: 0x1A1A1A, dark: 0xE4E4E4)
    static let directoryText = dynamic(light: 0x0B2E6B, dark: 0xA9C7FF)
    static let hiddenText = dynamic(light: 0x5F6368, dark: 0x9AA0A6)
    static let selectedText = dynamic(light: 0xC8102E, dark: 0xFF7B72)
    static let cursorBackground = dynamic(light: 0x2B5797, dark: 0x3A68AE)
    static let cursorText = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let cursorSelectedText = dynamic(light: 0xFFE27A, dark: 0xFFE27A)
    /// Cursor outline in the inactive pane.
    static let inactiveCursor = dynamic(light: 0x8A9BB5, dark: 0x6B7A93)

    // Path header above each pane
    static let headerActiveBackground = dynamic(light: 0x2B5797, dark: 0x3A68AE)
    static let headerActiveText = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let headerInactiveBackground = dynamic(light: 0xD9DEE6, dark: 0x34373D)
    static let headerInactiveText = dynamic(light: 0x1A1A1A, dark: 0xE4E4E4)

    // Bars (drive bar, status line, function-key bar)
    static let barBackground = dynamic(light: 0xE8EBF0, dark: 0x2A2C30)
    static let barText = dynamic(light: 0x1A1A1A, dark: 0xE4E4E4)
    static let separator = dynamic(light: 0xC3C9D3, dark: 0x45484E)
    static let errorText = dynamic(light: 0xB00020, dark: 0xFF8A80)

    /// Secondary text (hints, counts, states) in dialogs, settings and the queue panel. The system's
    /// secondary label colour renders at about 3.5:1 on light window backgrounds. This one is about 8:1
    /// (light) and 5:1 (dark) as specified; small text renders lighter through antialiasing, so keep margin.
    static let secondaryText = dynamic(light: 0x474747, dark: 0xB0B0B0)
    /// The SwiftUI form of `secondaryText`: the primary label colour at 85 percent (about 9:1 light,
    /// 8:1 dark; 75 percent was flagged "nearly passed" on a wrapped hint). Not `Color(nsColor: secondaryText)`: the accessibility audit misreads SwiftUI text
    /// drawn in a custom dynamic NSColor and reports a contrast failure for it in dark mode.
    static var secondaryTextColor: Color { Color.primary.opacity(0.85) }
    static var errorTextColor: Color { Color(nsColor: errorText) }

    // Compare by Content: row backgrounds for lines or bytes that differ (the Status column says
    // the same in words). Theme.text stays above 10:1 on all of them.
    static let compareChanged = dynamic(light: 0xFFF1BF, dark: 0x4A4120)
    static let compareOnlyLeft = dynamic(light: 0xFFDEDE, dark: 0x4D2828)
    static let compareOnlyRight = dynamic(light: 0xD9F3DD, dark: 0x1F4228)

    // Progress bars (queue panel). Outline and fill keep at least 3:1 against the window background
    // (WCAG non-text contrast); the track itself is transparent.
    static let progressOutline = dynamic(light: 0x767676, dark: 0x8E8E93)
    static let progressFill = dynamic(light: 0x2B5797, dark: 0x6FA8FF)

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
