import Foundation

/// The quick-filter matcher (Cmd+S).
///
/// Syntax (case-insensitive):
/// - `apple`            - name contains "apple"
/// - `*.mp3`            - wildcard, whole-name match (`*` any run, `?` one character)
/// - `*.mp3;*.flac`     - any of several patterns
/// - `*.* | *.tmp;~*`   - include patterns, then exclusions after the first `|`
/// - regex mode         - the whole text is one case-insensitive regular expression (searched, not anchored)
public struct NameFilter: Sendable {
    public enum ParseError: Error, Equatable {
        case invalidRegex(String)
    }

    private enum Pattern: Sendable {
        case substring([Character])
        case wildcard([Character])
    }

    private let includes: [Pattern]
    private let excludes: [Pattern]
    private let regex: NSRegularExpression?

    public let text: String
    public let isRegex: Bool

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    public init(_ text: String, regex isRegex: Bool = false) throws {
        self.text = text
        self.isRegex = isRegex
        if isRegex {
            do {
                regex = try NSRegularExpression(pattern: text, options: [.caseInsensitive])
            } catch {
                throw ParseError.invalidRegex(text)
            }
            includes = []
            excludes = []
            return
        }
        regex = nil
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        includes = Self.parsePatterns(parts.first.map(String.init) ?? "")
        excludes = parts.count > 1 ? Self.parsePatterns(String(parts[1])) : []
    }

    public func matches(_ name: String) -> Bool {
        if let regex {
            let range = NSRange(name.startIndex..., in: name)
            return regex.firstMatch(in: name, range: range) != nil
        }
        let lowered = Array(name.lowercased())
        if !includes.isEmpty, !includes.contains(where: { Self.match($0, lowered) }) { return false }
        return !excludes.contains(where: { Self.match($0, lowered) })
    }

    private static func parsePatterns(_ text: String) -> [Pattern] {
        text.split(separator: ";").compactMap { raw in
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { return nil }
            return p.contains(where: { $0 == "*" || $0 == "?" }) ? .wildcard(Array(p)) : .substring(Array(p))
        }
    }

    private static func match(_ pattern: Pattern, _ name: [Character]) -> Bool {
        switch pattern {
        case .substring(let needle): contains(name, needle)
        case .wildcard(let glob): wildcardMatch(glob, name)
        }
    }

    private static func contains(_ hay: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= hay.count else { return false }
        if needle.isEmpty { return true }
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            var i = 1
            while i < needle.count, hay[start + i] == needle[i] { i += 1 }
            if i == needle.count { return true }
        }
        return false
    }

    /// Iterative glob match with single-star backtracking: O(n*m) worst case, no recursion.
    private static func wildcardMatch(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0
        var starP = -1, starS = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi; starS = si; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starS += 1; si = starS
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
