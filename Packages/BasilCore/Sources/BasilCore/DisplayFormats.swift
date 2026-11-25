import Foundation

// MARK: - Size

public enum SizeUnit: String, Codable, CaseIterable, Sendable {
    case bytes, kilobytes, megabytes, gigabytes
    /// The largest unit in which the value is at least 1 (e.g. 900 KB, 1.5 MB, 2.1 GB).
    case dynamic

    public var title: String {
        switch self {
        case .bytes: "Bytes"
        case .kilobytes: "KB"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        case .dynamic: "Dynamic (largest fitting unit)"
        }
    }
}

public struct SizeFormat: Codable, Equatable, Sendable {
    public var unit: SizeUnit
    /// 1024 (binary, like Total Commander) or 1000 (decimal, like Finder).
    public var base: Int

    public init(unit: SizeUnit = .dynamic, base: Int = 1024) {
        self.unit = unit
        self.base = base == 1000 ? 1000 : 1024
    }

    private static let unitNames = ["B", "KB", "MB", "GB", "TB", "PB"]

    public func string(_ bytes: Int64) -> String {
        let exponent: Int
        switch unit {
        case .bytes: exponent = 0
        case .kilobytes: exponent = 1
        case .megabytes: exponent = 2
        case .gigabytes: exponent = 3
        case .dynamic:
            var e = 0
            var value = Double(bytes)
            while value >= Double(base), e < Self.unitNames.count - 1 {
                value /= Double(base)
                e += 1
            }
            exponent = e
        }
        if exponent == 0 { return Self.grouped(bytes) + " B" }
        let value = Double(bytes) / pow(Double(base), Double(exponent))
        return Self.decimal(value) + " " + Self.unitNames[exponent]
    }

    /// One decimal below 100, none from 100 up ("1.5 MB", "123 MB"); "0" only for exactly zero.
    static func decimal(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value >= 100 { return String(format: "%.0f", value.rounded()) }
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.1" } // never show a non-empty file as 0
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }

    static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return value < 0 ? "-" + out : out
    }
}

// MARK: - Date

public enum TimeFormat: String, Codable, CaseIterable, Sendable {
    case system, twentyFourHour, twelveHour, hidden

    public var title: String {
        switch self {
        case .system: "System setting"
        case .twentyFourHour: "24-hour"
        case .twelveHour: "12-hour"
        case .hidden: "No time"
        }
    }
}

public struct DateFormatSettings: Codable, Equatable, Sendable {
    /// Unicode date pattern for the date part, e.g. "yyyy-MM-dd". Empty means the system's short date.
    public var datePattern: String
    public var time: TimeFormat
    /// Dates in the last week read "5 minutes ago", "3 hours ago", "2 days ago"; older ones (and
    /// dates in the future) use the pattern.
    public var relative: Bool

    public init(datePattern: String = "", time: TimeFormat = .system, relative: Bool = false) {
        self.datePattern = datePattern
        self.time = time
        self.relative = relative
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        datePattern = try c.decodeIfPresent(String.self, forKey: .datePattern) ?? ""
        time = try c.decodeIfPresent(TimeFormat.self, forKey: .time) ?? .system
        relative = try c.decodeIfPresent(Bool.self, forKey: .relative) ?? false
    }

    /// "just now", "1 minute ago", "5 hours ago", "6 days ago"; nil when the date is in the
    /// future or a week or more ago.
    public static func relativeText(_ date: Date, now: Date = Date()) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= -1, seconds < 7 * 86_400 else { return nil }
        func ago(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return ago(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return ago(Int(seconds / 3_600), "hour") }
        return ago(Int(seconds / 86_400), "day")
    }

    /// Ready-made date patterns offered in settings (custom patterns are also allowed).
    public static let presets: [(title: String, pattern: String)] = [
        ("System", ""),
        ("2026-11-18 (yyyy-MM-dd)", "yyyy-MM-dd"),
        ("18.11.2026 (dd.MM.yyyy)", "dd.MM.yyyy"),
        ("18/11/2026 (dd/MM/yyyy)", "dd/MM/yyyy"),
        ("11/18/2026 (MM/dd/yyyy)", "MM/dd/yyyy"),
        ("11-18-2026 (MM-dd-yyyy)", "MM-dd-yyyy"),
    ]

    /// The full pattern used by DateFormatter.
    public func pattern(locale: Locale = .current) -> String {
        let datePart = datePattern.isEmpty
            ? (DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "yyyy-MM-dd")
            : datePattern
        let timePart: String?
        switch time {
        case .hidden: timePart = nil
        case .twentyFourHour: timePart = "HH:mm"
        case .twelveHour: timePart = "h:mm a"
        case .system: timePart = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        }
        return timePart.map { datePart + " " + $0 } ?? datePart
    }
}

/// Formatters built from the current settings. Formatting is thread-safe, so this is Sendable.
public final class DisplayFormatters: @unchecked Sendable {
    public let size: SizeFormat
    public let relativeDates: Bool
    private let dateFormatter: DateFormatter

    public init(size: SizeFormat, date: DateFormatSettings, locale: Locale = .current) {
        self.size = size
        relativeDates = date.relative
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = date.pattern(locale: locale)
        dateFormatter = f
    }

    public func date(_ value: Date?, now: Date = Date()) -> String {
        guard let value else { return "" }
        if relativeDates, let text = DateFormatSettings.relativeText(value, now: now) { return text }
        return dateFormatter.string(from: value)
    }
}
