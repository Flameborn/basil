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

@Suite struct DirectoryTotalsTests {
    let provider = LocalProvider()

    @Test func addsUpNestedFilesWithoutFollowingLinks() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "hello")
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try tmp.file("sub/b", "abc")
        try tmp.file("sub/deep/c", "xy")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("link").path, withDestinationPath: "sub")
        let linkSize = try await provider.item(at: tmp.vfs.appending("link")).size ?? 0

        let totals = try await provider.totals(of: tmp.vfs)
        #expect(totals.files == 4)
        #expect(totals.folders == 2)
        #expect(totals.bytes == 10 + linkSize)
        #expect(totals.unreadable == 0)
    }

    @Test func skipsUnreadableSubfoldersButFailsForTheFolderItself() async throws {
        let tmp = try TempDir()
        let locked = tmp.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try tmp.file("locked/x", "1234")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let totals = try await provider.totals(of: tmp.vfs)
        #expect(totals.folders == 1)
        #expect(totals.unreadable == 1)
        await #expect(throws: (any Error).self) { try await provider.totals(of: tmp.vfs.appending("locked")) }
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

    @Test func reportsRemovedChildAfterRename() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt")
        let stream = try #require(LocalProvider().watch(tmp.vfs))
        try await Task.sleep(for: .milliseconds(300))
        let a = tmp.vfs.appending("a.txt"), b = tmp.vfs.appending("b.txt")
        try await LocalProvider().rename(a, to: b, replacing: false)
        try await Task.sleep(for: .milliseconds(500))
        try await LocalProvider().remove(b)
        let seen = await withTaskGroup(of: [VFSChange].self) { group in
            group.addTask {
                var all: [VFSChange] = []
                for await c in stream { all.append(c); if all.count >= 3 { break } }
                return all
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return [] }
            var result: [VFSChange] = []
            for await r in group { result += r; if !r.isEmpty { group.cancelAll() } else { group.cancelAll() } }
            return result
        }
        print("SEEN", seen)
        #expect(seen.contains(.item(b)))
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

/// A provider that only has a location, for registry bookkeeping tests.
private struct StubProvider: FileSystemProvider {
    let location: ProviderLocation
    var capabilities: ProviderCapabilities { [] }
    func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> { AsyncThrowingStream { $0.finish() } }
    func item(at path: VFSPath) async throws -> FileItem { throw VFSError.notFound(path) }
    func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }
}

@Suite struct CloseContainersTests {
    let outer = ProviderLocation(provider: ProviderID("archive"), container: .local("/tmp/outer.zip"))
    var inner: ProviderLocation { ProviderLocation(provider: ProviderID("archive"), container: VFSPath(location: outer, path: "/inner.7z")) }
    let other = ProviderLocation(provider: ProviderID("archive"), container: .local("/tmp/other.zip"))

    func registry() -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        for location in [outer, inner, other] { registry.register(StubProvider(location: location)) }
        return registry
    }

    @Test func keepsShownContainersAndTheOnesAroundThem() throws {
        let registry = registry()
        let closed = registry.closeContainers(keeping: [inner])
        #expect(closed == [other])
        #expect(try registry.provider(for: outer).location == outer)
        #expect(try registry.provider(for: inner).location == inner)
        #expect(throws: VFSError.self) { try registry.provider(for: other) }
    }

    @Test func keepingTheOuterClosesTheNested() throws {
        let registry = registry()
        #expect(Set(registry.closeContainers(keeping: [outer, .local])) == [inner, other])
        #expect(try registry.provider(for: outer).location == outer)
    }

    @Test func neverClosesLocal() throws {
        let registry = registry()
        #expect(registry.closeContainers(keeping: []).count == 3)
        #expect(try registry.provider(for: .local).location == .local)
    }
}
