// Multi-rename rules, like Total Commander's Multi-Rename Tool: a name mask and an extension
// mask with placeholders, then search and replace, then case conversion. Pure string work with
// no file access, so the dialog can preview it and plugins can add placeholders.
//
// Placeholders (in both masks):
//   [N]        the old name without extension      [E]       the old extension
//   [N3]       third character of the name         [N2-5]    characters 2 to 5
//   [N2-]      from character 2 to the end         [N2,3]    3 characters from character 2
//   [N-3-]     the last 3 characters               [N2--2]   from 2 to the second-to-last
//              (the same ranges work for [E])
//   [P]        parent folder name                  [G]       grandparent folder name
//   [C]        counter (start, step and digits set in the dialog)
//   [C10+5:3]  counter starting at 10, step 5, 3 digits
//   [Y] year (4 digits), [y] year (2 digits), [M] month, [D] day, [h] hour, [m] minute,
//   [s] second: the modification date
//   [=name]    a placeholder registered by a plugin (MultiRenamePlaceholders.register)
// "[[" gives a literal "[" and "]]" a literal "]". Anything else in brackets is kept as typed.

import Foundation

public enum RenameCase: String, Codable, CaseIterable, Sendable {
    case unchanged, lower, upper, firstUpper, wordsUpper

    public var title: String {
        switch self {
        case .unchanged: "Unchanged"
        case .lower: "lowercase"
        case .upper: "UPPERCASE"
        case .firstUpper: "First letter uppercase"
        case .wordsUpper: "First Letter Of Each Word Uppercase"
        }
    }
}

/// Everything set in the Multi-Rename dialog. Saved as presets.
public struct RenameRule: Codable, Equatable, Hashable, Sendable {
    public var nameMask = "[N]"
    public var extensionMask = "[E]"
    public var search = ""
    public var replace = ""
    public var regex = false
    public var caseSensitive = false
    public var nameCase = RenameCase.unchanged
    public var counterStart = 1
    public var counterStep = 1
    public var counterDigits = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenameRule()
        nameMask = try c.decodeIfPresent(String.self, forKey: .nameMask) ?? d.nameMask
        extensionMask = try c.decodeIfPresent(String.self, forKey: .extensionMask) ?? d.extensionMask
        search = try c.decodeIfPresent(String.self, forKey: .search) ?? d.search
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? d.replace
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? d.regex
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? d.caseSensitive
        nameCase = try c.decodeIfPresent(RenameCase.self, forKey: .nameCase) ?? d.nameCase
        counterStart = try c.decodeIfPresent(Int.self, forKey: .counterStart) ?? d.counterStart
        counterStep = try c.decodeIfPresent(Int.self, forKey: .counterStep) ?? d.counterStep
        counterDigits = try c.decodeIfPresent(Int.self, forKey: .counterDigits) ?? d.counterDigits
    }
}

public struct RenamePreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var rule: RenameRule

    public init(id: UUID = UUID(), name: String, rule: RenameRule) {
        self.id = id
        self.name = name
        self.rule = rule
    }
}

/// What a placeholder sees: the item and its position in the batch (0-based).
public struct RenameInput: Sendable {
    public let item: FileItem
    public let index: Int
    /// The old name split like the masks see it: name without extension, and extension.
    public let baseName: String
    public let fileExtension: String

    public init(item: FileItem, index: Int) {
        self.item = item
        self.index = index
        (baseName, fileExtension) = item.nameAndExtension
    }
}

/// Placeholders added by plugins, used as "[=name]" in a mask.
public enum MultiRenamePlaceholders {
    public struct Definition: Sendable {
        public let name: String
        public let title: String
        public let value: @Sendable (RenameInput) -> String

        public init(name: String, title: String, value: @escaping @Sendable (RenameInput) -> String) {
            self.name = name
            self.title = title
            self.value = value
        }
    }

    private static let storage = PlaceholderStorage()

    public static func register(_ definition: Definition) { storage.set(definition) }
    public static func unregister(_ name: String) { storage.remove(name) }
    public static func definition(_ name: String) -> Definition? { storage.get(name) }
    public static var all: [Definition] { storage.all() }
}

private final class PlaceholderStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var defs: [String: Definition] = [:]
    typealias Definition = MultiRenamePlaceholders.Definition

    func set(_ d: Definition) {
        lock.withLock {
            if defs[d.name] == nil { order.append(d.name) }
            defs[d.name] = d
        }
    }
    func get(_ name: String) -> Definition? { lock.withLock { defs[name] } }
    func remove(_ name: String) {
        lock.withLock {
            defs[name] = nil
            order.removeAll { $0 == name }
        }
    }
    func all() -> [Definition] { lock.withLock { order.compactMap { defs[$0] } } }
}

public enum MultiRename {
    /// The new name for one item, or nil when the search pattern is an invalid regex.
    public static func newName(for input: RenameInput, rule: RenameRule, calendar: Calendar = .current) -> String? {
        let base = expand(rule.nameMask, input, rule, calendar)
        let ext = expand(rule.extensionMask, input, rule, calendar)
        var name = ext.isEmpty ? base : "\(base).\(ext)"
        if !rule.search.isEmpty {
            guard let replaced = replace(in: name, rule) else { return nil }
            name = replaced
        }
        return convertCase(name, rule.nameCase)
    }

    /// Checks the search pattern; returns the error text for an invalid regex.
    public static func searchError(_ rule: RenameRule) -> String? {
        guard rule.regex, !rule.search.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: rule.search, options: rule.caseSensitive ? [] : [.caseInsensitive])
            return nil
        } catch {
            return "The search pattern is not a valid regular expression"
        }
    }

    // MARK: Masks

    static func expand(_ mask: String, _ input: RenameInput, _ rule: RenameRule, _ calendar: Calendar) -> String {
        var out = ""
        var i = mask.startIndex
        while i < mask.endIndex {
            let c = mask[i]
            let next = mask.index(after: i)
            if c == "[", next < mask.endIndex, mask[next] == "[" {
                out.append("["); i = mask.index(after: next); continue
            }
            if c == "]", next < mask.endIndex, mask[next] == "]" {
                out.append("]"); i = mask.index(after: next); continue
            }
            if c == "[", let close = mask[next...].firstIndex(of: "]") {
                let token = String(mask[next..<close])
                if let value = placeholder(token, input, rule, calendar) {
                    out += value
                    i = mask.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = next
        }
        return out
    }

    static func placeholder(_ token: String, _ input: RenameInput, _ rule: RenameRule, _ calendar: Calendar) -> String? {
        guard let first = token.first else { return nil }
        let rest = String(token.dropFirst())
        switch first {
        case "N": return range(rest, of: input.baseName)
        case "E": return range(rest, of: input.fileExtension)
        case "P" where rest.isEmpty: return input.item.path.parent?.name ?? ""
        case "G" where rest.isEmpty: return input.item.path.parent?.parent?.name ?? ""
        case "C": return counter(rest, input.index, rule)
        case "=": return MultiRenamePlaceholders.definition(rest)?.value(input)
        case "Y", "y", "M", "D", "h", "m", "s":
            guard rest.isEmpty else { return nil }
            guard let date = input.item.modified else { return "" }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
            switch first {
            case "Y": return String(format: "%04d", parts.year ?? 0)
            case "y": return two((parts.year ?? 0) % 100)
            case "M": return two(parts.month)
            case "D": return two(parts.day)
            case "h": return two(parts.hour)
            case "m": return two(parts.minute)
            default: return two(parts.second)
            }
        default: return nil
        }
    }

    /// "" whole; "3" one character; "2-5", "2-", "-3-", "2--2" ranges; "2,3" a count from a start.
    /// Positions are 1-based; negative ones count from the end (-1 is the last character).
    /// Nil when the text is not a range, so the placeholder is kept as typed.
    static func range(_ spec: String, of text: String) -> String? {
        let chars = Array(text)
        guard !spec.isEmpty else { return text }
        var scanner = Substring(spec)
        guard let start = signedInt(&scanner) else { return nil }
        func index(_ n: Int) -> Int { n < 0 ? chars.count + n : n - 1 } // 0-based
        let from = index(start)
        var to: Int
        if scanner.isEmpty {
            to = from
        } else if scanner.first == "," {
            scanner.removeFirst()
            guard let count = Int(scanner), count >= 0 else { return nil }
            to = from + count - 1
        } else if scanner.first == "-" {
            scanner.removeFirst()
            if scanner.isEmpty {
                to = chars.count - 1
            } else {
                guard let end = signedInt(&scanner), scanner.isEmpty else { return nil }
                to = index(end)
            }
        } else {
            return nil
        }
        let lo = max(0, from)
        to = min(chars.count - 1, to)
        guard lo <= to else { return "" }
        return String(chars[lo...to])
    }

    private static func signedInt(_ s: inout Substring) -> Int? {
        var digits = ""
        if s.first == "-" { digits.append("-"); s.removeFirst() }
        while let c = s.first, c.isASCII, c.isNumber { digits.append(c); s.removeFirst() }
        guard let n = Int(digits), n != 0 else { return nil }
        return n
    }

    /// "" uses the dialog's counter; "10+5:3" sets start, step and digits (each part optional).
    static func counter(_ spec: String, _ index: Int, _ rule: RenameRule) -> String? {
        var start = rule.counterStart, step = rule.counterStep, digits = rule.counterDigits
        if !spec.isEmpty {
            var s = Substring(spec)
            func number() -> Int? {
                var d = ""
                while let c = s.first, c.isASCII, c.isNumber { d.append(c); s.removeFirst() }
                return Int(d)
            }
            if let n = number() { start = n }
            if s.first == "+" { s.removeFirst(); guard let n = number() else { return nil }; step = n }
            if s.first == ":" { s.removeFirst(); guard let n = number() else { return nil }; digits = n }
            guard s.isEmpty else { return nil }
        }
        let value = start + index * step
        let text = String(abs(value))
        let padded = String(repeating: "0", count: max(0, digits - text.count)) + text
        return value < 0 ? "-" + padded : padded
    }

    // MARK: Search, replace, case

    static func replace(in name: String, _ rule: RenameRule) -> String? {
        if rule.regex {
            guard let re = try? NSRegularExpression(pattern: rule.search,
                                                    options: rule.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
            return re.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name),
                                               withTemplate: rule.replace)
        }
        return name.replacingOccurrences(of: rule.search, with: rule.replace,
                                         options: rule.caseSensitive ? [] : [.caseInsensitive])
    }

    static func convertCase(_ name: String, _ mode: RenameCase) -> String {
        switch mode {
        case .unchanged: return name
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        case .firstUpper:
            let lower = name.lowercased()
            guard let first = lower.first else { return lower }
            return first.uppercased() + lower.dropFirst()
        case .wordsUpper:
            var out = ""
            var startOfWord = true
            for c in name.lowercased() {
                out += startOfWord ? c.uppercased() : String(c)
                startOfWord = !(c.isLetter || c.isNumber || c == "'")
            }
            return out
        }
    }
}

// MARK: Preview

/// One line of the preview grid.
public struct RenamePreviewEntry: Sendable, Equatable, Identifiable {
    public enum Problem: Sendable, Equatable {
        case empty
        case invalidCharacter
        /// Another item in the batch gets the same name.
        case duplicate
        /// An item that is not renamed already has this name.
        case exists

        public var text: String {
            switch self {
            case .empty: "empty name"
            case .invalidCharacter: "name contains a slash"
            case .duplicate: "same new name as another item"
            case .exists: "an item with this name already exists"
            }
        }
    }

    public var id: VFSPath { item.path }
    public let item: FileItem
    public let newName: String
    public let problem: Problem?

    public var isUnchanged: Bool { newName == item.name }
}

public enum MultiRenamePreview {
    /// New names for `items` (in batch order). `existingNames` are the names of everything in the
    /// folder, renamed or not. Names are compared without case, as on a default APFS volume.
    public static func make(items: [FileItem], rule: RenameRule, existingNames: some Sequence<String>,
                            calendar: Calendar = .current) -> [RenamePreviewEntry] {
        let folders = Set(items.compactMap(\.path.parent))
        let names = Set(existingNames)
        return make(items: items, rule: rule, existingNamesByFolder: Dictionary(uniqueKeysWithValues: folders.map { ($0, names) }),
                    calendar: calendar)
    }

    /// The same for items from several folders (search results): names clash only with names in
    /// the item's own folder. `existingNamesByFolder` has the names of everything in each folder.
    public static func make(items: [FileItem], rule: RenameRule, existingNamesByFolder: [VFSPath: Set<String>],
                            calendar: Calendar = .current) -> [RenamePreviewEntry] {
        let names = items.enumerated().map { index, item in
            MultiRename.newName(for: RenameInput(item: item, index: index), rule: rule, calendar: calendar) ?? item.name
        }
        struct Key: Hashable { let folder: VFSPath?; let name: String }
        let renamed = Set(items.map { Key(folder: $0.path.parent, name: $0.name.lowercased()) })
        var untouched: Set<Key> = []
        for (folder, existing) in existingNamesByFolder {
            for name in existing { untouched.insert(Key(folder: folder, name: name.lowercased())) }
        }
        untouched.subtract(renamed)
        var counts: [Key: Int] = [:]
        for (item, name) in zip(items, names) { counts[Key(folder: item.path.parent, name: name.lowercased()), default: 0] += 1 }
        return zip(items, names).map { item, name in
            let key = Key(folder: item.path.parent, name: name.lowercased())
            let problem: RenamePreviewEntry.Problem?
            if name.isEmpty || name == "." || name == ".." {
                problem = .empty
            } else if name.contains("/") || name.contains("\0") {
                problem = .invalidCharacter
            } else if counts[key, default: 0] > 1 {
                problem = .duplicate
            } else if untouched.contains(key) {
                problem = .exists
            } else {
                problem = nil
            }
            return RenamePreviewEntry(item: item, newName: name, problem: problem)
        }
    }
}
