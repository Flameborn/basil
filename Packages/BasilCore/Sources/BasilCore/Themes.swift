import Foundation

/// Every colour of Basil's own UI, by name. A theme gives each a light and a dark value.
public enum ThemeToken: String, CaseIterable, Codable, Sendable {
    case paneBackground, alternateRow, text, directoryText, hiddenText, selectedText
    case cursorBackground, cursorText, cursorSelectedText, inactiveCursor
    case headerActiveBackground, headerActiveText, headerInactiveBackground, headerInactiveText
    case barBackground, barText, separator, errorText, secondaryText
    case compareChanged, compareOnlyLeft, compareOnlyRight
    case progressOutline, progressFill

    /// For Settings and speech.
    public var title: String {
        switch self {
        case .paneBackground: "Pane background"
        case .alternateRow: "Alternate rows"
        case .text: "Text"
        case .directoryText: "Folder names"
        case .hiddenText: "Hidden items"
        case .selectedText: "Selected items"
        case .cursorBackground: "Cursor"
        case .cursorText: "Text on the cursor"
        case .cursorSelectedText: "Selected items on the cursor"
        case .inactiveCursor: "Cursor in the other pane"
        case .headerActiveBackground: "Path bar of the active pane"
        case .headerActiveText: "Path bar text, active pane"
        case .headerInactiveBackground: "Path bar of the other pane"
        case .headerInactiveText: "Path bar text, other pane"
        case .barBackground: "Bars (status line, function keys)"
        case .barText: "Bar text"
        case .separator: "Separators"
        case .errorText: "Errors"
        case .secondaryText: "Secondary text"
        case .compareChanged: "Compare: changed rows"
        case .compareOnlyLeft: "Compare: rows only on the left"
        case .compareOnlyRight: "Compare: rows only on the right"
        case .progressOutline: "Progress bar outline"
        case .progressFill: "Progress bar fill"
        }
    }

    /// Basil's own colours (light, dark).
    public var defaults: (light: UInt32, dark: UInt32) {
        switch self {
        case .paneBackground: (0xFFFFFF, 0x1E1F22)
        case .alternateRow: (0xF4F6F9, 0x24262A)
        case .text: (0x1A1A1A, 0xE4E4E4)
        case .directoryText: (0x0B2E6B, 0xA9C7FF)
        case .hiddenText: (0x5F6368, 0x9AA0A6)
        case .selectedText: (0xC8102E, 0xFF7B72)
        case .cursorBackground: (0x2B5797, 0x3865AA)
        case .cursorText: (0xFFFFFF, 0xFFFFFF)
        case .cursorSelectedText: (0xFFE27A, 0xFFE27A)
        case .inactiveCursor: (0x7E8EA6, 0x6B7A93)
        case .headerActiveBackground: (0x2B5797, 0x3865AA)
        case .headerActiveText: (0xFFFFFF, 0xFFFFFF)
        case .headerInactiveBackground: (0xD9DEE6, 0x34373D)
        case .headerInactiveText: (0x1A1A1A, 0xE4E4E4)
        case .barBackground: (0xE8EBF0, 0x2A2C30)
        case .barText: (0x1A1A1A, 0xE4E4E4)
        case .separator: (0xC3C9D3, 0x45484E)
        case .errorText: (0xB00020, 0xFF8A80)
        case .secondaryText: (0x474747, 0xB0B0B0)
        case .compareChanged: (0xFFF1BF, 0x4A4120)
        case .compareOnlyLeft: (0xFFDEDE, 0x4D2828)
        case .compareOnlyRight: (0xD9F3DD, 0x1F4228)
        case .progressOutline: (0x767676, 0x8E8E93)
        case .progressFill: (0x2B5797, 0x6FA8FF)
        }
    }
}

/// One token's two values.
public struct ThemeColor: Codable, Hashable, Sendable {
    public var light: UInt32
    public var dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public func value(dark isDark: Bool) -> UInt32 { isDark ? dark : light }

    /// "#1A2B3C"
    public static func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xFFFFFF) }

    /// Reads "#1A2B3C", "1A2B3C" or "#ABC".
    public static func parse(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return value
    }

    // The file form: { "light": "#FFFFFF", "dark": "#1E1F22" }.
    enum CodingKeys: String, CodingKey { case light, dark }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) throws -> UInt32 {
            let text = try c.decode(String.self, forKey: key)
            guard let value = Self.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "\(text) is not a colour like #1A2B3C")
            }
            return value
        }
        light = try read(.light)
        dark = try read(.dark)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.hex(light), forKey: .light)
        try c.encode(Self.hex(dark), forKey: .dark)
    }
}

/// A colour theme: a name and a value for each token (tokens left out take Basil's own).
/// Saved in settings, and as JSON files (".basiltheme") for import and export.
public struct ThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var colors: [ThemeToken: ThemeColor]

    public init(id: String, name: String, colors: [ThemeToken: ThemeColor] = [:]) {
        self.id = id
        self.name = name
        self.colors = colors
    }

    public static let builtinID = "basil"
    /// Basil's own theme, which cannot be changed (duplicate it to make one of your own).
    public static let builtin = ThemeDefinition(
        id: builtinID, name: "Basil",
        colors: Dictionary(uniqueKeysWithValues: ThemeToken.allCases.map { ($0, ThemeColor(light: $0.defaults.light, dark: $0.defaults.dark)) }))

    public var isBuiltin: Bool { id == Self.builtinID }

    public func color(_ token: ThemeToken) -> ThemeColor {
        colors[token] ?? ThemeColor(light: token.defaults.light, dark: token.defaults.dark)
    }

    enum CodingKeys: String, CodingKey { case id, name, colors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent([String: ThemeColor].self, forKey: .colors) ?? [:]
        // Unknown names (from a newer Basil) are left out.
        colors = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in ThemeToken(rawValue: key).map { ($0, value) } })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }), forKey: .colors)
    }
}

/// WCAG 2 contrast between the colours that are used together. Text needs 4.5 to 1 (AA),
/// outlines and fills 3 to 1 (non-text contrast).
public enum ThemeContrast {
    public struct Pair: Sendable, Equatable {
        public var foreground: ThemeToken
        public var background: ThemeToken
        public var minimum: Double
        public var title: String { "\(foreground.title) on \(background.title.lowercased())" }
    }

    public struct Problem: Sendable, Equatable, CustomStringConvertible {
        public var pair: Pair
        public var dark: Bool
        public var ratio: Double
        public var description: String {
            "\(pair.title) would be \(Self.format(ratio)) to 1 in \(dark ? "dark" : "light") mode; it needs \(Self.format(pair.minimum)) to 1"
        }
        static func format(_ value: Double) -> String { String(format: "%.1f", value) }
    }

    public static let pairs: [Pair] = {
        var result: [Pair] = []
        func add(_ f: ThemeToken, on backgrounds: [ThemeToken], _ minimum: Double = 4.5) {
            for b in backgrounds { result.append(Pair(foreground: f, background: b, minimum: minimum)) }
        }
        let rows: [ThemeToken] = [.paneBackground, .alternateRow]
        add(.text, on: rows + [.compareChanged, .compareOnlyLeft, .compareOnlyRight])
        add(.directoryText, on: rows)
        add(.hiddenText, on: rows)
        add(.selectedText, on: rows)
        add(.cursorText, on: [.cursorBackground])
        add(.cursorSelectedText, on: [.cursorBackground])
        add(.headerActiveText, on: [.headerActiveBackground])
        add(.headerInactiveText, on: [.headerInactiveBackground])
        add(.barText, on: [.barBackground])
        add(.errorText, on: [.barBackground, .paneBackground])
        add(.secondaryText, on: [.paneBackground, .barBackground])
        add(.inactiveCursor, on: rows, 3)
        add(.progressOutline, on: [.paneBackground], 3)
        add(.progressFill, on: [.paneBackground], 3)
        return result
    }()

    /// WCAG relative luminance of an sRGB colour (0xRRGGBB).
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Every pair below its minimum, in light and in dark mode.
    public static func problems(_ theme: ThemeDefinition) -> [Problem] {
        var found: [Problem] = []
        for pair in pairs {
            for dark in [false, true] {
                let r = ratio(theme.color(pair.foreground).value(dark: dark), theme.color(pair.background).value(dark: dark))
                if r < pair.minimum { found.append(Problem(pair: pair, dark: dark, ratio: r)) }
            }
        }
        return found
    }

    /// Each pair's ratio in light and dark mode, for the contrast list in Settings.
    public static func report(_ theme: ThemeDefinition) -> [(pair: Pair, light: Double, dark: Double)] {
        pairs.map { pair in
            (pair, ratio(theme.color(pair.foreground).light, theme.color(pair.background).light),
             ratio(theme.color(pair.foreground).dark, theme.color(pair.background).dark))
        }
    }
}
