import Foundation

public enum SortKey: String, Sendable, Codable, CaseIterable {
    case name, ext, size, modified, created
    /// The order the provider listed the items in (TC "Unsorted"), folders still first.
    case unsorted
}

public struct ListSortOrder: Sendable, Equatable, Codable {
    public var key: SortKey
    public var ascending: Bool
    /// Folders (and links to folders) before files. Off sorts them in with the files by the key.
    public var foldersFirst: Bool
    public init(key: SortKey, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    private enum CodingKeys: String, CodingKey { case key, ascending, foldersFirst }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(SortKey.self, forKey: .key) ?? .name
        ascending = try c.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
    }
    public static let `default` = ListSortOrder(key: .name)
}

/// Total Commander-style ordering: directories (and links to directories) come first
/// (unless `foldersFirst` is off); ties fall back to a natural, case-insensitive name comparison.
public enum ItemSorter {
    public static func sorted(_ items: [FileItem], by order: ListSortOrder) -> [FileItem] {
        if order.key == .unsorted {
            guard order.foldersFirst else { return items }
            return items.filter(\.isDirectoryLike) + items.filter { !$0.isDirectoryLike }
        }
        // Precompute keys once, then sort indices: avoids moving large structs and repeated string work.
        let keys = items.map(Keyed.init)
        var indices = Array(keys.indices)
        keys.withUnsafeBufferPointer { k in
            indices.sort { areInIncreasingOrder(k[$0], k[$1], order) }
        }
        return indices.map { items[$0] }
    }

    /// Index at which `item` should be inserted into an already sorted array.
    public static func insertionIndex(of item: FileItem, in sorted: [FileItem], by order: ListSortOrder) -> Int {
        if order.key == .unsorted {
            // New items go last among the folders or among the files.
            guard order.foldersFirst else { return sorted.count }
            return item.isDirectoryLike ? (sorted.firstIndex { !$0.isDirectoryLike } ?? sorted.count) : sorted.count
        }
        let key = Keyed(item)
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if areInIncreasingOrder(Keyed(sorted[mid]), key, order) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private struct Keyed {
        let isDir: Bool
        let size: Int64
        let modified: Date
        let created: Date
        let rawName: String
        let name: [UInt32]
        let ext: [UInt32]
        init(_ item: FileItem) {
            isDir = item.isDirectoryLike
            size = item.size ?? 0
            modified = item.modified ?? .distantPast
            created = item.created ?? .distantPast
            rawName = item.name
            name = NaturalKey.make(item.name)
            ext = NaturalKey.make(item.nameAndExtension.ext)
        }
    }

    private static func areInIncreasingOrder(_ a: Keyed, _ b: Keyed, _ order: ListSortOrder) -> Bool {
        if order.foldersFirst, a.isDir != b.isDir { return a.isDir }
        let primary: ComparisonResult
        switch order.key {
        case .name:
            primary = .orderedSame
        case .ext:
            // Folders have no extension (they sort with extensionless files when mixed in).
            primary = NaturalKey.compare(a.isDir ? [] : a.ext, b.isDir ? [] : b.ext)
        case .size:
            primary = compare(a.size, b.size)
        case .modified:
            primary = compare(a.modified, b.modified)
        case .created:
            primary = compare(a.created, b.created)
        case .unsorted:
            primary = .orderedSame // handled in sorted(_:by:) and insertionIndex
        }
        var result = primary != .orderedSame ? primary : NaturalKey.compare(a.name, b.name)
        if result == .orderedSame { result = compare(a.rawName, b.rawName) } // stable, deterministic tie-break
        if result == .orderedSame { return false }
        return (result == .orderedAscending) == order.ascending
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

/// Finder-like natural ordering, precomputed once per name for speed:
/// case-, width- and diacritic-insensitive, with digit runs compared numerically ("file2" < "file10").
enum NaturalKey {
    static func make(_ s: String) -> [UInt32] {
        // Fast path for ASCII (the common case): fold case by hand instead of via Foundation.
        if s.utf8.allSatisfy({ $0 < 128 }) {
            return s.utf8.map { b in UInt32(b >= 65 && b <= 90 ? b + 32 : b) }
        }
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.map(\.value)
    }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> ComparisonResult {
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let ca = a[i], cb = b[j]
            if isDigit(ca), isDigit(cb) {
                // Compare digit runs numerically: skip leading zeros, then by length, then digit by digit.
                var si = i, sj = j
                while si < a.count, a[si] == 48 { si += 1 }
                while sj < b.count, b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < a.count, isDigit(a[ei]) { ei += 1 }
                while ej < b.count, isDigit(b[ej]) { ej += 1 }
                let la = ei - si, lb = ej - sj
                if la != lb { return la < lb ? .orderedAscending : .orderedDescending }
                var k = 0
                while k < la {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? .orderedAscending : .orderedDescending }
                    k += 1
                }
                i = ei; j = ej
                continue
            }
            if ca != cb { return ca < cb ? .orderedAscending : .orderedDescending }
            i += 1; j += 1
        }
        if a.count - i == b.count - j { return .orderedSame }
        return i == a.count ? .orderedAscending : .orderedDescending
    }

    @inline(__always) private static func isDigit(_ c: UInt32) -> Bool { c >= 48 && c <= 57 }
}
