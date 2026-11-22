import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// File lists (.lst, like TC's DiskDir): written from the pack dialog, browsed like a folder,
/// nothing else works in them.
@Suite struct FileListTests {
    func prepared() throws -> (Fixture, FileListOpener) {
        let f = try Fixture()
        let lists = FileListOpener()
        f.registry.register(opener: lists)
        f.registry.register(writer: lists)
        return (f, lists)
    }

    @Test(arguments: ["lst-optimised", "lst"])
    func writeAndBrowse(format: String) async throws {
        let (f, lists) = try prepared()
        _ = try await lists.create(f.path("music.lst"), options: PackOptions(format: format), changes: try await f.srcAdds(),
                                   replacing: false, registry: f.registry, monitor: WriteMonitor())
        #expect(try f.leftovers().isEmpty)
        let root = try await f.open("music.lst")
        #expect(root.location.provider == .fileList)
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "folder", "hello.txt", "link"])
        #expect(try await f.names(root.appending("folder")) == ["big.bin", "deeper"])
        let provider = try f.registry.provider(for: root.location)
        let big = try await provider.item(at: root.appending("folder/big.bin"))
        let original = try await f.registry.provider(for: .local).item(at: f.src.appending("folder/big.bin"))
        #expect(big.size == Int64(Fixture.big.count))
        #expect(big.modified == original.modified)
        #expect(big.permissions == original.permissions)
        // Folder sizes come from the list.
        let totals = try await provider.totals(of: root.appending("folder"))
        #expect(totals.bytes == Int64(Fixture.big.count + 4))
        #expect(totals.files == 2)
        #expect(totals.folders == 1)
        let folder = try await provider.item(at: root.appending("folder"))
        #expect(folder.kind == .directory)
        let link = try await provider.item(at: root.appending("link"))
        #expect(link.kind == .symlink(target: .directory))
    }

    @Test func everythingButBrowsingIsRefused() async throws {
        let (f, lists) = try prepared()
        _ = try await lists.create(f.path("a.lst"), options: PackOptions(format: "lst-optimised"),
                                   changes: try await f.srcAdds(), replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("a.lst")
        let provider = try f.registry.writableProvider(for: root.location)
        #expect(!provider.capabilities.contains(.read))
        await #expect(throws: VFSError.self) { _ = try await provider.openForReading(root.appending("hello.txt"), bypassCache: false) }
        await #expect(throws: VFSError.self) { try await provider.remove(root.appending("hello.txt")) }
        await #expect(throws: VFSError.self) { try await provider.makeDirectory(root.appending("New")) }
        #expect(lists.updateRefusal(for: f.path("a.lst"), registry: f.registry)?.contains("file list") == true)
        await #expect(throws: VFSError.self) {
            _ = try await lists.update(f.path("a.lst"), changes: [.delete("/hello.txt")], macMetadata: false,
                                       registry: f.registry, monitor: WriteMonitor())
        }
        // Copying out fails through the engine too.
        let queue = await FileOperationQueue()
        let item = await queue.add(TransferOperation(mode: .copy, sources: [root.appending("hello.txt")], target: f.src.appending("folder"),
                                                     registry: f.registry, options: SecureCopyOptions()))
        let deadline = ContinuousClock.now + .seconds(10)
        while await !item.state.isDone, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await item.state != .finished)
        #expect(!FileManager.default.fileExists(atPath: f.src.appending("folder/hello.txt").path))
    }

    @Test func packOperationWritesAList() async throws {
        let (f, _) = try prepared()
        let queue = await FileOperationQueue()
        let op = PackOperation(jobs: [.init(archive: f.path("src.lst"), sources: [f.src])], options: PackOptions(format: "lst"),
                               storePaths: true, moveSources: false, unstableRetries: 0, registry: f.registry)
        let item = await queue.add(op)
        let deadline = ContinuousClock.now + .seconds(10)
        while await !item.state.isDone, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await item.state == .finished)
        let text = try String(contentsOf: f.url.appendingPathComponent("src.lst"), encoding: .utf8)
        #expect(text.hasPrefix(FileListFormat.header))
        #expect(text.contains("# Root: \(f.url.path)"))
        let root = try await f.open("src.lst")
        #expect(try await f.names(root.appending("src/folder/deeper")) == ["deep.txt"])
        // A test reads the list and finds nothing wrong.
        #expect(try await FileListOpener().test(f.path("src.lst"), registry: f.registry) { _, _ in }.isEmpty)
    }

    @Test func textEscapesAwkwardNames() throws {
        let entries = [FileListEntry(path: "a\tb\\c\nd", kind: .file, size: 3, modified: timespec(tv_sec: 1_700_000_000, tv_nsec: 500)),
                       FileListEntry(path: "dir", kind: .directory, permissions: 0o755),
                       FileListEntry(path: "dir/link", kind: .symlink, symlinkTarget: "../a\tb")]
        let text = FileListFormat.write(root: "/x", entries: entries)
        let parsed = try #require(FileListFormat.parse(Data(text.utf8)))
        #expect(parsed.flavor == .basil)
        #expect(parsed.root == "/x")
        #expect(parsed.entries == entries)
        let binary = try #require(FileListFormat.parse(FileListFormat.writeBinary(root: "/x", entries: entries)))
        #expect(binary.flavor == .optimised)
        #expect(binary.entries.count == 3)
        #expect(FileListOpener.same(binary.entries, entries))
    }

    @Test func binaryAddsImpliedFoldersAndRejectsDamage() throws {
        let entries = [FileListEntry(path: "a/b/c.txt", kind: .file, size: 1)]
        let data = FileListFormat.writeBinary(root: "/", entries: entries)
        let parsed = try #require(FileListFormat.parse(data))
        #expect(parsed.entries.map(\.path) == ["a", "a/b", "a/b/c.txt"])
        #expect(FileListFormat.parse(data.dropLast(3)) == nil)
    }

    @Test func readsDiskDirLists() async throws {
        let (f, _) = try prepared()
        let text = "C:\\Music\\\r\nAlbum\\\t0\t2010.5.3\t14:22.10\r\nAlbum\\track.mp3\t4523110\t2009.11.2\t9:01.55\r\nreadme.txt\t12\t2020.1.1\t0:00.00\r\n"
        try Data(text.utf8).write(to: f.url.appendingPathComponent("tc.lst"))
        let root = try await f.open("tc.lst")
        #expect(try await f.names(root) == ["Album", "readme.txt"])
        let provider = try f.registry.provider(for: root.location)
        let track = try await provider.item(at: root.appending("Album/track.mp3"))
        #expect(track.size == 4_523_110)
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2009, 11, 2, 9, 1, 55)
        #expect(track.modified == Calendar.current.date(from: c))
        #expect(try await provider.totals(of: root).bytes == 4_523_122)
        // Windows-1252 names work too.
        try Data([0x52, 0x6F, 0x6F, 0x74, 0x5C, 0x0A]
                 + Array("caf".utf8) + [0xE9] + Array("\t5\t2020.1.1\t0:00.00\n".utf8)).write(to: f.url.appendingPathComponent("w.lst"))
        #expect(try await f.names(try await f.open("w.lst")) == ["caf\u{E9}"])
    }

    @Test func otherTextFilesAreNotLists() {
        #expect(FileListFormat.parse(Data("hello\nworld\n".utf8)) == nil)
        #expect(FileListFormat.parse(Data("root\nname\tnot a size\n".utf8)) == nil)
    }
}
