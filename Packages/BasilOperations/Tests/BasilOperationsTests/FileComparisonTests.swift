import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilOperations

@Suite struct FileComparisonTests {
    private func compare(_ left: String, _ right: String) -> FileComparison {
        FileComparison.compare(Data(left.utf8), Data(right.utf8))
    }

    @Test func identicalFiles() throws {
        let result = compare("one\ntwo\n", "one\ntwo\n")
        #expect(result.identical)
        let text = try #require(result.text)
        #expect(text.differences.isEmpty)
        #expect(text.rows.map(\.status) == [.same, .same])
        #expect(result.binary.differingRowCount == 0)
    }

    @Test func changedInsertedAndRemovedLines() throws {
        let result = compare("a\nb\nc\nd\ne\n", "a\nB\nc\ne\nf\ng\n")
        #expect(!result.identical)
        #expect(result.firstDifference == 2)
        let text = try #require(result.text)
        #expect(text.rows == [
            TextCompareRow(status: .same, leftLine: 1, leftText: "a", rightLine: 1, rightText: "a"),
            TextCompareRow(status: .changed, leftLine: 2, leftText: "b", rightLine: 2, rightText: "B"),
            TextCompareRow(status: .same, leftLine: 3, leftText: "c", rightLine: 3, rightText: "c"),
            TextCompareRow(status: .onlyLeft, leftLine: 4, leftText: "d", rightLine: nil, rightText: nil),
            TextCompareRow(status: .same, leftLine: 5, leftText: "e", rightLine: 4, rightText: "e"),
            TextCompareRow(status: .onlyRight, leftLine: nil, leftText: nil, rightLine: 5, rightText: "f"),
            TextCompareRow(status: .onlyRight, leftLine: nil, leftText: nil, rightLine: 6, rightText: "g"),
        ])
        #expect(text.differences == [1, 3, 5])
    }

    @Test func onlyLineEndingsDiffer() throws {
        let result = compare("one\r\ntwo\r\n", "one\ntwo")
        #expect(!result.identical)
        let text = try #require(result.text)
        #expect(text.differences.isEmpty)
        #expect(text.onlyLineEndingsDiffer)
    }

    @Test func binaryFilesHaveNoTextView() throws {
        var left = Data((0 ..< 100).map { UInt8($0) })
        var right = left
        right[40] = 0xFF
        right.append(contentsOf: [1, 2, 3])
        let result = FileComparison.compare(left, right)
        #expect(result.text == nil)
        #expect(result.firstDifference == 40)
        let binary = result.binary
        #expect(binary.isComplete)
        #expect(binary.rowCount == 7)
        #expect(binary.differingRows == [2, 6])
        #expect(binary.differences == [0, 1])
        #expect(binary.row(at: 2)?.status == .changed)
        #expect(binary.row(at: 6)?.status == .changed)   // 4 bytes left, 7 right
        #expect(binary.row(at: 0)?.status == .same)
        left.append(contentsOf: (1 ... 20).map { UInt8($0) })   // 120 bytes: row 7 is only on the left
        let longer = FileComparison.compare(left, Data(left.prefix(100)))
        #expect(longer.binary.row(at: 7)?.status == .onlyLeft)
        #expect(longer.firstDifference == 100)
    }

    @Test func readsFilesThroughProviders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("basil-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Three chunks and a bit, differing in the second chunk and at the end.
        var a = Data(count: 3 * (1 << 20) + 5)
        for i in stride(from: 0, to: a.count, by: 4096) { a[i] = 7 }
        var b = a
        b[(1 << 20) + 17] = 1
        b.append(9)
        try a.write(to: dir.appendingPathComponent("a.bin"))
        try b.write(to: dir.appendingPathComponent("b.bin"))
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let result = try await FileComparison.compare(.local(dir.appendingPathComponent("a.bin").path),
                                                      .local(dir.appendingPathComponent("b.bin").path), registry: registry)
        #expect(result.leftSize == Int64(a.count) && result.rightSize == Int64(b.count))
        #expect(result.firstDifference == Int64((1 << 20) + 17))
        #expect(result.binary.differingRowCount == 2)
        #expect(result.text == nil)

        let same = try await FileComparison.compare(.local(dir.appendingPathComponent("a.bin").path),
                                                    .local(dir.appendingPathComponent("a.bin").path), registry: registry)
        #expect(same.identical)
    }
}
