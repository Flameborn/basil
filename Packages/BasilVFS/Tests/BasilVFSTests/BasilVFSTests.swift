import BasilCore
import Foundation
import Testing
@testable import BasilVFS

/// A fresh temp directory per test, removed afterwards.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var vfs: VFSPath { .local(url.path) }
    func file(_ name: String, _ content: String = "") throws {
        try Data(content.utf8).write(to: url.appendingPathComponent(name))
    }
}

func collect(_ stream: AsyncThrowingStream<[FileItem], Error>) async throws -> [FileItem] {
    var all: [FileItem] = []
    for try await batch in stream { all += batch }
    return all
}

@Suite struct LocalProviderListingTests {
    let provider = LocalProvider()

    @Test func listsFilesDirsSymlinksWithAttributes() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "hello")
        try tmp.file(".hidden")
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("link").path, withDestinationPath: "sub")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("dangling").path, withDestinationPath: "nope")

        let items = Dictionary(uniqueKeysWithValues: try await collect(provider.list(tmp.vfs)).map { ($0.name, $0) })
        #expect(Set(items.keys) == ["a.txt", ".hidden", "sub", "link", "dangling"])
        #expect(items["a.txt"]?.kind == .file)
        #expect(items["a.txt"]?.size == 5)
        #expect(items["a.txt"]?.modified != nil)
        #expect(items["a.txt"]?.fileID != nil)
        #expect(items["a.txt"]?.isHidden == false)
        #expect(items[".hidden"]?.isHidden == true)
        #expect(items["sub"]?.kind == .directory)
        #expect(items["sub"]?.size == nil)
        #expect(items["link"]?.kind == .symlink(target: .directory))
        #expect(items["link"]?.isDirectoryLike == true)
        #expect(items["dangling"]?.kind == .symlink(target: .broken))
        #expect(items["a.txt"]?.path == tmp.vfs.appending("a.txt"))
    }

    @Test func matchesStatForSingleItem() async throws {
        let tmp = try TempDir()
        try tmp.file("f", "12345678")
        let listed = try await collect(provider.list(tmp.vfs)).first
        let stat = try await provider.item(at: tmp.vfs.appending("f"))
        #expect(listed?.size == stat.size)
        #expect(listed?.fileID == stat.fileID)
        #expect(listed?.permissions == stat.permissions)
    }

    @Test func streamsLargeDirectoriesInBatches() async throws {
        let tmp = try TempDir()
        for i in 0..<5000 { try tmp.file("f\(i)") }
        var batches = 0
        var total = 0
        for try await batch in provider.list(tmp.vfs) { batches += 1; total += batch.count }
        #expect(total == 5000)
        #expect(batches >= 2)
    }

    @Test func missingDirectoryThrowsNotFound() async {
        let missing = VFSPath.local("/definitely/not/here-\(UUID())")
        await #expect(throws: VFSError.notFound(missing)) { try await collect(provider.list(missing)) }
    }
}

@Suite struct DirectoryWatcherTests {
    @Test func reportsCreatedChild() async throws {
        let tmp = try TempDir()
        let stream = try #require(LocalProvider().watch(tmp.vfs))
        try await Task.sleep(for: .milliseconds(300))
        try tmp.file("new.txt")
        let target = tmp.vfs.appending("new.txt")
        let change = await withTaskGroup(of: VFSChange?.self) { group in
            group.addTask { for await c in stream { if c == .item(target) { return c } }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(change == .item(target))
    }
}

@Suite struct ProviderRegistryTests {
    @Test func resolvesRegisteredProvider() throws {
        let registry = ProviderRegistry()
        #expect(throws: VFSError.self) { try registry.provider(for: .local) }
        registry.register(LocalProvider())
        #expect(try registry.provider(for: .local).location == .local)
    }
}
