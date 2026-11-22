import BasilCore
import Foundation

/// One entry of an FTP listing, before it becomes a `FileItem`.
struct FTPEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file, directory, other
        /// A link; the target when the listing names it.
        case symlink(String?)
    }

    var name: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
    var permissions: UInt16?
    /// True when `modified` has seconds (MLSD, MDTM); LIST has minutes or only days.
    var preciseTime: Bool = false
}

/// Parsers for the listing formats FTP servers send: MLSD/MLST facts (RFC 3659), Unix `ls -l`
/// style LIST lines and the DOS style of IIS. LIST times are read as UTC.
enum FTPListing {
    // MARK: MLSD

    /// "type=file;size=6;modify=20261122173014; name". nil for lines without facts.
    static func mlsd(_ line: String) -> FTPEntry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty else { return nil }
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
        }
        guard let type = facts["type"]?.lowercased() else { return nil }
        let kind: FTPEntry.Kind
        switch type {
        case "file": kind = .file
        case "dir": kind = .directory
        case "cdir", "pdir": return nil
        default:
            // "OS.unix=slink:/target", "OS.unix=symlink"
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
                let raw = facts["type"]!
                let target = raw.firstIndex(of: ":").map { String(raw[raw.index(after: $0)...]) }
                kind = .symlink(target?.isEmpty == false ? target : nil)
            } else if type.hasPrefix("os.unix=") || type == "os.unix" {
                kind = .other
            } else {
                kind = .other
            }
        }
        var entry = FTPEntry(name: name, kind: kind)
        if kind == .file { entry.size = facts["size"].flatMap { Int64($0) } }
        if let modify = facts["modify"], let date = timestamp(modify) {
            entry.modified = date
            entry.preciseTime = true
        }
        if let mode = facts["unix.mode"], let bits = UInt16(mode, radix: 8) { entry.permissions = bits & 0o7777 }
        return entry
    }

    /// "YYYYMMDDHHMMSS" with optional ".sss" fractions, UTC (MLSD modify, MDTM, MFMT).
    static func timestamp(_ text: String) -> Date? {
        let main = text.prefix { $0 != "." }
        guard main.count == 14, main.allSatisfy(\.isASCIIDigit) else { return nil }
        let digits = Array(main)
        func number(_ from: Int, _ count: Int) -> Int { Int(String(digits[from..<(from + count)]))! }
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = .gmt
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        guard var date = utcCalendar.date(from: components) else { return nil }
        if let dot = text.firstIndex(of: "."), let fraction = Double("0" + text[dot...]) {
            date += fraction
        }
        return date
    }

    /// The form MFMT and MDTM use.
    static func timestamp(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    // MARK: LIST

    /// One LIST line in Unix or DOS style. nil for "total" lines and anything unreadable.
    static func list(_ line: String, now: Date = Date()) -> FTPEntry? {
        if let entry = unix(line, now: now) { return entry }
        return dos(line)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Words with where each starts and ends in the line.
    private static func words(_ line: String) -> [(text: Substring, end: String.Index)] {
        var result: [(Substring, String.Index)] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            result.append((line[start..<index], index))
        }
        return result
    }

    /// "drwxr-xr-x 2 user group 4096 Nov 22 10:00 name", "lrwxrwxrwx 1 u g 4 Nov 22 2025 a -> b".
    /// The group (and on some servers the link count) may be missing, so the date is found
    /// first: a month name, a day and a time or year, with the size just before it.
    static func unix(_ line: String, now: Date) -> FTPEntry? {
        guard let type = line.first, "-dlbcps".contains(type) else { return nil }
        let w = words(line)
        guard w.count >= 6, w[0].text.count >= 10 else { return nil }
        let mode = w[0].text
        guard mode.dropFirst().prefix(9).allSatisfy({ "rwxsStTl-".contains($0) }) else { return nil }
        var found: Int?
        for i in 2..<(w.count - 2) where months.contains(w[i].text.lowercased()) {
            guard let day = Int(w[i + 1].text), (1...31).contains(day), Int64(w[i - 1].text) != nil else { continue }
            let third = w[i + 2].text
            if third.contains(":") || (third.count == 4 && Int(third) != nil) {
                found = i
                break
            }
        }
        guard let i = found, i + 3 <= w.count else { return nil }
        // The name starts after the single space that follows the time or year.
        var start = w[i + 2].end
        guard start < line.endIndex else { return nil }
        start = line.index(after: start)
        var name = String(line[start...])
        guard !name.isEmpty else { return nil }
        let kind: FTPEntry.Kind
        switch type {
        case "d": kind = .directory
        case "-": kind = .file
        case "l":
            var target: String?
            if let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
            kind = .symlink(target)
        default: kind = .other
        }
        if name == "." || name == ".." { return nil }
        var entry = FTPEntry(name: name, kind: kind)
        if kind == .file { entry.size = Int64(w[i - 1].text) }
        entry.modified = unixDate(month: String(w[i].text), day: Int(w[i + 1].text)!, timeOrYear: String(w[i + 2].text), now: now)
        entry.permissions = permissions(mode)
        return entry
    }

    /// "Nov 22 10:00" is within the last year (the year is left out); "Nov 22 2025" names it.
    private static func unixDate(month: String, day: Int, timeOrYear: String, now: Date) -> Date? {
        guard let monthIndex = months.firstIndex(of: month.lowercased()) else { return nil }
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = .gmt
        components.month = monthIndex + 1
        components.day = day
        if let colon = timeOrYear.firstIndex(of: ":") {
            components.hour = Int(timeOrYear[..<colon])
            components.minute = Int(timeOrYear[timeOrYear.index(after: colon)...])
            let year = utcCalendar.component(.year, from: now)
            components.year = year
            if let date = utcCalendar.date(from: components), date > now + 86_400 {
                components.year = year - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return utcCalendar.date(from: components)
    }

    /// "rwxr-x---" with setuid, setgid and sticky letters.
    static func permissions(_ mode: Substring) -> UInt16? {
        let letters = Array(mode.dropFirst().prefix(9))
        guard letters.count == 9 else { return nil }
        var bits: UInt16 = 0
        let shifts: [UInt16] = [6, 3, 0]
        for (group, shift) in shifts.enumerated() {
            let r = letters[group * 3], w = letters[group * 3 + 1], x = letters[group * 3 + 2]
            if r == "r" { bits |= 4 << shift }
            if w == "w" { bits |= 2 << shift }
            if "xst".contains(x) { bits |= 1 << shift }
            if "sS".contains(x) { bits |= group == 0 ? 0o4000 : 0o2000 }
            if "tT".contains(x), group == 2 { bits |= 0o1000 }
        }
        return bits
    }

    /// "11-22-26  10:00AM       <DIR>          name" or "2026-11-22  22:00  1234 name" (IIS).
    static func dos(_ line: String) -> FTPEntry? {
        let w = words(line)
        guard w.count >= 4 else { return nil }
        let date = w[0].text.split(separator: "-")
        guard date.count == 3, date.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        var time = w[1].text.uppercased()
        var pm = false
        if time.hasSuffix("PM") { pm = true; time.removeLast(2) } else if time.hasSuffix("AM") { time.removeLast(2) }
        let clock = time.split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        if pm, hour < 12 { hour += 12 }
        if !pm, w[1].text.uppercased().hasSuffix("AM"), hour == 12 { hour = 0 }
        var start = w[2].end
        guard start < line.endIndex else { return nil }
        // The name starts after the spaces that follow <DIR> or the size.
        while start < line.endIndex, line[start] == " " { start = line.index(after: start) }
        let name = String(line[start...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = .gmt
        if date[0].count == 4 {
            components.year = Int(date[0]); components.month = Int(date[1]); components.day = Int(date[2])
        } else {
            components.month = Int(date[0]); components.day = Int(date[1])
            let year = Int(date[2])!
            components.year = date[2].count == 2 ? (year < 70 ? 2000 + year : 1900 + year) : year
        }
        components.hour = hour
        components.minute = minute
        let isDirectory = w[2].text.uppercased() == "<DIR>"
        if !isDirectory, Int64(w[2].text) == nil { return nil }
        var entry = FTPEntry(name: name, kind: isDirectory ? .directory : .file)
        if !isDirectory { entry.size = Int64(w[2].text) }
        entry.modified = utcCalendar.date(from: components)
        return entry
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
