import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilSync

/// Two folders with files at chosen dates.
struct Trees {
    let root: URL
    var left: URL { root.appendingPathComponent("L") }
    var right: URL { root.appendingPathComponent("R") }
    let registry = ProviderRegistry()

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-sync-\(UUID().uuidString)")
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(url.path, &buffer)))
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        registry.register(LocalProvider())
    }

    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    func put(_ side: URL, _ relative: String, _ text: String, at offset: TimeInterval = 0) throws {
        let file = side.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Self.base.addingTimeInterval(offset)], ofItemAtPath: file.path)
    }

    func compare(_ options: SyncOptions = SyncOptions()) async throws -> [SyncEntry] {
        try await SyncComparer.compare(left: .local(left.path), right: .local(right.path), options: options, registry: registry)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

func byPath(_ entries: [SyncEntry]) -> [String: SyncEntry] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.relative, $0) })
}

@Suite struct SyncCompareTests {
    @Test func comparesBySizeAndDateLikeTotalCommander() async throws {
        let t = try Trees()
        defer { t.cleanUp() }
        try t.put(t.left, "same.txt", "abc")
        try t.put(t.right, "same.txt", "abc")
        try t.put(t.left, "newer-left.txt", "new", at: 60)
        try t.put(t.right, "newer-left.txt", "old")
        try t.put(t.left, "newer-right.txt", "a")
        try t.put(t.right, "newer-right.txt", "bb", at: 60)
        try t.put(t.left, "same-date.txt", "short")
        try t.put(t.right, "same-date.txt", "longer text")
        try t.put(t.left, "only-left.txt", "x")
        try t.put(t.right, "Only Right/a.txt", "12345")
        try t.put(t.right, "Only Right/deep/b.txt", "67")
        try t.put(t.left, "Sub/inner.txt", "1", at: 10)
        try t.put(t.right, "Sub/inner.txt", "1")
        try t.put(t.left, "Readme.TXT", "r")
        try t.put(t.right, "readme.txt", "r")
        let e = byPath(try await t.compare())
        #expect(e["same.txt"]?.state == .equal && e["same.txt"]?.action == SyncAction.none)
        #expect(e["newer-left.txt"]?.state == .leftNewer && e["newer-left.txt"]?.action == .copyRight)
        #expect(e["newer-right.txt"]?.state == .rightNewer && e["newer-right.txt"]?.action == .copyLeft)
        #expect(e["same-date.txt"]?.state == .different && e["same-date.txt"]?.action == SyncAction.none)
        #expect(e["only-left.txt"]?.state == .leftOnly && e["only-left.txt"]?.action == .copyRight)
        let folder = try #require(e["Only Right"])
        #expect(folder.state == .rightOnly && folder.action == .copyLeft && folder.isFolder)
        #expect(folder.folderFiles == 2 && folder.right?.size == 7 && folder.copyBytes == 7)
        #expect(e["Sub/inner.txt"]?.state == .leftNewer)
        #expect(e["Readme.TXT"]?.state == .equal, "names match without case")
        #expect(e.count == 8)
        #expect(SyncOperation.summary(Array(e.values)).hasPrefix("Copy 3 files to the right"))
        #expect(SyncOperation.summary(Array(e.values)).contains("3 files to the left"))
    }

    @Test func optionsChangeTheAnswers() async throws {
        let t = try Trees()
        defer { t.cleanUp() }
        try t.put(t.left, "a.txt", "same", at: 1)
        try t.put(t.right, "a.txt", "same")
        try t.put(t.left, "dst.txt", "same", at: 3600)
        try t.put(t.right, "dst.txt", "same")
        try t.put(t.left, "content.txt", "aaaa", at: 100)
        try t.put(t.right, "content.txt", "aaaa")
        try t.put(t.left, "differs.txt", "aaaa")
        try t.put(t.right, "differs.txt", "bbbb")
        try t.put(t.left, "pic.jpg", "j")
        try t.put(t.left, "Sub/x.txt", "x")
        var options = SyncOptions()
        var e = byPath(try await t.compare(options))
        #expect(e["a.txt"]?.state == .leftNewer, "0 seconds tolerance by default")
        #expect(e["dst.txt"]?.state == .leftNewer)
        #expect(e["differs.txt"]?.state == .equal, "same size and date without content comparison")

        options.toleranceSeconds = 2
        options.ignoreHour = true
        e = byPath(try await t.compare(options))
        #expect(e["a.txt"]?.state == .equal)
        #expect(e["dst.txt"]?.state == .equal)

        options.byContent = true
        e = byPath(try await t.compare(options))
        #expect(e["content.txt"]?.state == .equal, "same content counts as equal whatever the dates")
        #expect(e["differs.txt"]?.state == .different)

        options.filter = "*.txt"
        options.subfolders = false
        e = byPath(try await t.compare(options))
        #expect(e["pic.jpg"] == nil && e["Sub"] == nil && e["Sub/x.txt"] == nil)
        options.subfolders = true
        e = byPath(try await t.compare(options))
        // With a filter, a one-sided folder is listed file by file.
        #expect(e["Sub/x.txt"]?.state == .leftOnly && e["Sub"] == nil)
    }

    @Test func asymmetricMakesTheRightLikeTheLeft() async throws {
        let t = try Trees()
        defer { t.cleanUp() }
        try t.put(t.right, "extra.txt", "x")
        try t.put(t.left, "f.txt", "a")
        try t.put(t.right, "f.txt", "b", at: 60)
        var options = SyncOptions()
        options.asymmetric = true
        let e = byPath(try await t.compare(options))
        #expect(e["extra.txt"]?.action == .deleteRight)
        #expect(e["f.txt"]?.state == .rightNewer && e["f.txt"]?.action == SyncAction.none)
    }
}

@MainActor
@Suite struct SyncOperationTests {
    @Test func synchronizesBothWaysThenEverythingIsEqual() async throws {
        let t = try Trees()
        defer { t.cleanUp() }
        try t.put(t.left, "a.txt", "new left", at: 60)
        try t.put(t.right, "a.txt", "old")
        try t.put(t.right, "b.txt", "new right", at: 60)
        try t.put(t.left, "b.txt", "old")
        try t.put(t.left, "Deep/Er/c.txt", "c")
        try t.put(t.right, "Folder/x.txt", "x")
        try t.put(t.right, "Folder/y/z.txt", "z")
        var entries = try await t.compare()
        // The user leaves b.txt alone.
        if let i = entries.firstIndex(where: { $0.relative == "b.txt" }) { entries[i].action = .none }
        let queue = FileOperationQueue()
        let item = queue.add(SyncOperation(left: .local(t.left.path), right: .local(t.right.path), entries: entries,
                                           registry: t.registry, options: SecureCopyOptions(secure: true)))
        for _ in 0..<500 where !item.state.isDone { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.state == .finished, "\(item.log)")
        #expect(try String(contentsOf: t.right.appendingPathComponent("a.txt"), encoding: .utf8) == "new left")
        #expect(try String(contentsOf: t.right.appendingPathComponent("Deep/Er/c.txt"), encoding: .utf8) == "c")
        #expect(try String(contentsOf: t.left.appendingPathComponent("Folder/y/z.txt"), encoding: .utf8) == "z")
        #expect(try String(contentsOf: t.left.appendingPathComponent("b.txt"), encoding: .utf8) == "old")
        let after = try await t.compare()
        #expect(after.filter { $0.state != .equal }.map(\.relative) == ["b.txt"])
    }

    @Test func asymmetricDeletesOnTheRight() async throws {
        let t = try Trees()
        defer { t.cleanUp() }
        try t.put(t.left, "keep.txt", "k")
        try t.put(t.right, "keep.txt", "k")
        try t.put(t.right, "gone.txt", "g")
        try t.put(t.right, "Gone Folder/inner.txt", "i")
        var options = SyncOptions()
        options.asymmetric = true
        let entries = try await t.compare(options)
        var operation = SyncOperation(left: .local(t.left.path), right: .local(t.right.path), entries: entries,
                                      registry: t.registry, options: SecureCopyOptions())
        operation.useTrash = false
        #expect(SyncOperation.summary(entries) == "Delete 2 files on the right")
        let queue = FileOperationQueue()
        let item = queue.add(operation)
        for _ in 0..<500 where !item.state.isDone { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.state == .finished, "\(item.log)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.right.path) == ["keep.txt"])
    }
}
