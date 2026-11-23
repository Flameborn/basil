import BasilCore
import BasilVFS
import Foundation

/// Compare by Content, like Total Commander's: two files are read through their providers and
/// compared byte for byte; text files also get a line-by-line comparison. The result has rows
/// for a table (lines, or blocks of 16 bytes) with a status each, and the runs of rows that
/// differ ("differences") for jumping from one to the next.
public enum CompareStatus: String, Sendable {
    case same = "Same"
    case changed = "Changed"
    case onlyLeft = "Only left"
    case onlyRight = "Only right"
}

/// One row of the text comparison: a line of each file (or of one, when the other has none there).
public struct TextCompareRow: Sendable, Equatable {
    public var status: CompareStatus
    public var leftLine: Int?
    public var leftText: String?
    public var rightLine: Int?
    public var rightText: String?
}

/// One row of the binary comparison: 16 bytes of each file at `offset` (fewer at the end).
public struct BinaryCompareRow: Sendable, Equatable {
    public var status: CompareStatus
    public var offset: Int64
    public var left: Data
    public var right: Data
}

public struct TextComparison: Sendable {
    public var rows: [TextCompareRow]
    /// Indices of the rows that start a run of differing rows.
    public var differences: [Int]
    /// Same lines, but the files use different line endings (CR LF and LF) or one lacks the
    /// final line break.
    public var onlyLineEndingsDiffer: Bool
}

/// The binary rows. Files up to `FileComparison.fullBinaryLimit` keep every row; larger files
/// only the rows that differ (up to `maxStoredRows`).
public struct BinaryComparison: Sendable {
    public static let rowSize = 16
    public static let maxStoredRows = 100_000

    let left: Data?
    let right: Data?
    /// Rows that differ (all of them when complete, the first `maxStoredRows` otherwise).
    public let differingRows: [Int64]
    let storedRows: [Int64: BinaryCompareRow]
    /// Number of 16-byte rows that differ, also those not stored.
    public let differingRowCount: Int64
    /// Every row is available (`row(at:)` for any index below `rowCount`).
    public var isComplete: Bool { left != nil }
    public let rowCount: Int64

    public func row(at index: Int64) -> BinaryCompareRow? {
        if let stored = storedRows[index] { return stored }
        guard let left, let right, index >= 0, index < rowCount else { return nil }
        let start = Int(index) * Self.rowSize
        func slice(_ data: Data) -> Data {
            guard start < data.count else { return Data() }
            return data.subdata(in: data.startIndex + start ..< data.startIndex + min(data.count, start + Self.rowSize))
        }
        let l = slice(left), r = slice(right)
        return BinaryCompareRow(status: Self.status(l, r), offset: Int64(start), left: l, right: r)
    }

    static func status(_ left: Data, _ right: Data) -> CompareStatus {
        if left == right { return .same }
        if left.isEmpty { return .onlyRight }
        if right.isEmpty { return .onlyLeft }
        return .changed
    }

    /// Indices (in `differingRows`) that start a run of consecutive differing rows.
    public var differences: [Int] {
        differingRows.indices.filter { $0 == 0 || differingRows[$0 - 1] != differingRows[$0] - 1 }
    }
}

public struct FileComparison: Sendable {
    /// Up to this size per file the binary view has every row and text files are compared by line.
    public static let fullBinaryLimit: Int64 = 64 << 20
    public static let textLimit: Int64 = 16 << 20

    public let leftSize: Int64
    public let rightSize: Int64
    public var identical: Bool { firstDifference == nil }
    /// Byte offset of the first difference.
    public let firstDifference: Int64?
    /// Nil when either file is not text, or too big for the text view.
    public let text: TextComparison?
    public let binary: BinaryComparison

    /// Reads both files (in parallel chunks) and compares them. Cancelling the task stops it;
    /// `progress` gets the fraction read.
    public static func compare(_ left: VFSPath, _ right: VFSPath, registry: ProviderRegistry,
                               progress: @Sendable (Double) -> Void = { _ in }) async throws -> FileComparison {
        let leftProvider = try registry.writableProvider(for: left.location)
        let rightProvider = try registry.writableProvider(for: right.location)
        let leftSize = try await leftProvider.item(at: left).size ?? 0
        let rightSize = try await rightProvider.item(at: right).size ?? 0
        let keep = max(leftSize, rightSize) <= fullBinaryLimit
        let leftFile = try await leftProvider.openForReading(left, bypassCache: false)
        let rightFile: any ReadableFile
        do { rightFile = try await rightProvider.openForReading(right, bypassCache: false) } catch {
            await leftFile.close()
            throw error
        }
        do {
            var builder = try await read(leftFile, rightFile, keepAll: keep, total: max(1, max(leftSize, rightSize)),
                                         progress: progress)
            let result = builder.finish(leftSize: leftSize, rightSize: rightSize)
            await leftFile.close()
            await rightFile.close()
            return result
        } catch {
            await leftFile.close()
            await rightFile.close()
            throw error
        }
    }

    private static func read(_ leftFile: any ReadableFile, _ rightFile: any ReadableFile, keepAll: Bool, total: Int64,
                             progress: @Sendable (Double) -> Void) async throws -> Builder {
        let chunk = 1 << 20
        var builder = Builder(keepAll: keepAll)
        var offset: Int64 = 0
        var leftDone = false, rightDone = false
        while !(leftDone && rightDone) {
            try Task.checkCancellation()
            let at = offset, readLeft = !leftDone, readRight = !rightDone
            async let l = readLeft ? leftFile.read(at: at, count: chunk) : Data()
            async let r = readRight ? rightFile.read(at: at, count: chunk) : Data()
            let (a, b) = try await (l, r)
            if a.count < chunk { leftDone = true }
            if b.count < chunk { rightDone = true }
            builder.add(left: a, right: b, at: offset)
            offset += Int64(max(a.count, b.count))
            progress(min(1, Double(offset) / Double(total)))
        }
        return builder
    }

    /// Compares two files already in memory (tests, and the work behind `compare`).
    public static func compare(_ left: Data, _ right: Data) -> FileComparison {
        var builder = Builder(keepAll: true)
        builder.add(left: left, right: right, at: 0)
        return builder.finish(leftSize: Int64(left.count), rightSize: Int64(right.count))
    }

    struct Builder {
        let keepAll: Bool
        var left = Data(), right = Data()
        var firstDifference: Int64?
        var differing: [Int64] = []
        var differingCount: Int64 = 0
        var stored: [Int64: BinaryCompareRow] = [:]
        var pendingLeft = Data(), pendingRight = Data()
        var pendingOffset: Int64 = 0

        init(keepAll: Bool) { self.keepAll = keepAll }

        /// Both files are read at the same offsets, so every chunk lines up and can be compared
        /// whole (a side that ended adds nothing).
        mutating func add(left a: Data, right b: Data, at offset: Int64) {
            if keepAll { left += a; right += b }
            pendingLeft += a
            pendingRight += b
            consume(max(pendingLeft.count, pendingRight.count))
        }

        private mutating func consume(_ count: Int) {
            guard count > 0 else { return }
            let size = BinaryComparison.rowSize
            var start = 0
            while start < count {
                let l = slice(pendingLeft, start, size), r = slice(pendingRight, start, size)
                if l != r {
                    let row = (pendingOffset + Int64(start)) / Int64(size)
                    if firstDifference == nil {
                        let common = zip(l, r).prefix { $0 == $1 }.count
                        firstDifference = pendingOffset + Int64(start + common)
                    }
                    differingCount += 1
                    if differing.count < BinaryComparison.maxStoredRows {
                        differing.append(row)
                        if !keepAll {
                            stored[row] = BinaryCompareRow(status: BinaryComparison.status(l, r),
                                                           offset: row * Int64(size), left: l, right: r)
                        }
                    }
                }
                start += size
            }
            pendingLeft = pendingLeft.count > count ? Data(pendingLeft.dropFirst(count)) : Data()
            pendingRight = pendingRight.count > count ? Data(pendingRight.dropFirst(count)) : Data()
            pendingOffset += Int64(count)
        }

        private func slice(_ data: Data, _ start: Int, _ size: Int) -> Data {
            guard start < data.count else { return Data() }
            return data.subdata(in: data.startIndex + start ..< data.startIndex + min(data.count, start + size))
        }

        mutating func finish(leftSize: Int64, rightSize: Int64) -> FileComparison {
            consume(max(pendingLeft.count, pendingRight.count))
            let rowSize = Int64(BinaryComparison.rowSize)
            let rowCount = (max(leftSize, rightSize) + rowSize - 1) / rowSize
            let binary = BinaryComparison(left: keepAll ? left : nil, right: keepAll ? right : nil,
                                          differingRows: differing, storedRows: stored,
                                          differingRowCount: differingCount, rowCount: rowCount)
            var text: TextComparison?
            if keepAll, Int64(left.count) <= FileComparison.textLimit, Int64(right.count) <= FileComparison.textLimit,
               let l = TextLines(left), let r = TextLines(right) {
                text = TextDiff.compare(l, r, bytesIdentical: firstDifference == nil)
            }
            return FileComparison(leftSize: leftSize, rightSize: rightSize, firstDifference: firstDifference,
                                  text: text, binary: binary)
        }
    }
}

/// A file's lines, when it is text: no NUL bytes; UTF-8, else Windows-1252.
struct TextLines {
    var lines: [String]

    init?(_ data: Data) {
        guard !data.contains(0) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        guard let text else { return nil }
        var lines: [String] = []
        var current = Substring(text)
        // "\r\n" is one Character in Swift.
        while let newline = current.firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lines.append(String(current[..<newline]))
            current = current[current.index(after: newline)...]
        }
        if !current.isEmpty { lines.append(String(current)) }
        self.lines = lines
    }
}

enum TextDiff {
    static func compare(_ left: TextLines, _ right: TextLines, bytesIdentical: Bool) -> TextComparison {
        let a = left.lines, b = right.lines
        // Common start and end first, so the diff only sees the part that changed.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix ..< a.count - suffix]), midB = Array(b[prefix ..< b.count - suffix])
        let diff = midB.difference(from: midA)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [TextCompareRow] = []
        rows.reserveCapacity(max(a.count, b.count))
        func same(_ i: Int, _ j: Int) {
            rows.append(TextCompareRow(status: .same, leftLine: i + 1, leftText: a[i], rightLine: j + 1, rightText: b[j]))
        }
        for k in 0 ..< prefix { same(k, k) }
        var i = 0, j = 0
        while i < midA.count || j < midB.count {
            if (i < midA.count && removed.contains(i)) || (j < midB.count && inserted.contains(j)) {
                var gone: [Int] = [], added: [Int] = []
                while i < midA.count, removed.contains(i) { gone.append(i); i += 1 }
                while j < midB.count, inserted.contains(j) { added.append(j); j += 1 }
                for k in 0 ..< max(gone.count, added.count) {
                    let l = k < gone.count ? gone[k] + prefix : nil
                    let r = k < added.count ? added[k] + prefix : nil
                    let status: CompareStatus = l != nil && r != nil ? .changed : (l != nil ? .onlyLeft : .onlyRight)
                    rows.append(TextCompareRow(status: status, leftLine: l.map { $0 + 1 }, leftText: l.map { a[$0] },
                                               rightLine: r.map { $0 + 1 }, rightText: r.map { b[$0] }))
                }
            } else {
                same(i + prefix, j + prefix)
                i += 1
                j += 1
            }
        }
        for k in 0 ..< suffix { same(a.count - suffix + k, b.count - suffix + k) }

        let differences = rows.indices.filter { rows[$0].status != .same && ($0 == 0 || rows[$0 - 1].status == .same) }
        return TextComparison(rows: rows, differences: differences,
                              onlyLineEndingsDiffer: differences.isEmpty && !bytesIdentical)
    }
}
