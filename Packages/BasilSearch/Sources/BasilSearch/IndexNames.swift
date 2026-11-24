import BasilCore
import Foundation

/// The quick-filter syntax (`NameFilter`) matched against names stored as lowercased UTF-8
/// bytes, so millions of index entries are checked without making a String for each.
/// `*` is any run of bytes, `?` one character (one UTF-8 sequence). Regular expressions are
/// matched on the original name instead (`needsOriginalName`).
struct FoldedNameMatcher: Sendable {
    private enum Pattern: Sendable {
        case substring([UInt8])
        case wildcard([UInt8])
    }

    private let includes: [Pattern]
    private let excludes: [Pattern]
    /// Set for regex mode: names are matched as Strings.
    let regexFilter: NameFilter?

    var needsOriginalName: Bool { regexFilter != nil }

    init(_ text: String, regex: Bool) throws {
        if regex {
            regexFilter = try NameFilter(text, regex: true)
            includes = []
            excludes = []
            return
        }
        regexFilter = nil
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        includes = Self.parse(parts.first.map(String.init) ?? "")
        excludes = parts.count > 1 ? Self.parse(String(parts[1])) : []
    }

    /// Lowercased and precomposed (names on disk are often decomposed, typed text precomposed).
    static func fold(_ name: String) -> [UInt8] { Array(name.lowercased().precomposedStringWithCanonicalMapping.utf8) }

    private static func parse(_ text: String) -> [Pattern] {
        text.split(separator: ";").compactMap { raw in
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
            guard !p.isEmpty else { return nil }
            let bytes = Array(p.utf8)
            return p.contains(where: { $0 == "*" || $0 == "?" }) ? .wildcard(bytes) : .substring(bytes)
        }
    }

    /// `folded`: the lowercased UTF-8 name.
    func matches(folded: UnsafeBufferPointer<UInt8>) -> Bool {
        if !includes.isEmpty, !includes.contains(where: { Self.match($0, folded) }) { return false }
        return !excludes.contains { Self.match($0, folded) }
    }

    private static func match(_ pattern: Pattern, _ name: UnsafeBufferPointer<UInt8>) -> Bool {
        switch pattern {
        case .substring(let needle):
            guard needle.count <= name.count else { return false }
            return needle.withUnsafeBytes { n in memmem(name.baseAddress, name.count, n.baseAddress, n.count) != nil }
        case .wildcard(let glob):
            return wildcard(glob, name)
        }
    }

    /// Glob with single-star backtracking; `?` takes one whole UTF-8 sequence.
    private static func wildcard(_ p: [UInt8], _ s: UnsafeBufferPointer<UInt8>) -> Bool {
        func next(_ i: Int) -> Int {
            var j = i + 1
            while j < s.count, s[j] & 0xC0 == 0x80 { j += 1 }
            return j
        }
        var pi = 0, si = 0
        var starP = -1, starS = 0
        let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
        while si < s.count {
            if pi < p.count, p[pi] == question {
                pi += 1; si = next(si)
            } else if pi < p.count, p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == star {
                starP = pi; starS = si; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starS = next(starS); si = starS
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == star { pi += 1 }
        return pi == p.count
    }
}
