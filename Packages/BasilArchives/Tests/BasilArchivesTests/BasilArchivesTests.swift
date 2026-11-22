import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// A fresh temporary folder per test with a few files to pack, removed afterwards.
final class Fixture: Sendable {
    let url: URL
    let registry = ProviderRegistry()
    let opener: ArchiveOpener

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-archive-\(UUID().uuidString)")
        let src = url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("folder/deeper"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("hello.txt"))
        try Self.big.write(to: src.appendingPathComponent("folder/big.bin"))
        try Data("deep".utf8).write(to: src.appendingPathComponent("folder/deeper/deep.txt"))
        try Data("unicode".utf8).write(to: src.appendingPathComponent("Grüße änd ü.txt"))
        try Data("hidden".utf8).write(to: src.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "folder")
        registry.register(LocalProvider())
        opener = ArchiveOpener(temporaryRoot: url.appendingPathComponent("tmp"))
        registry.register(opener: opener)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static let big: Data = {
        var d = Data(count: 3 << 20)
        d.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        }
        return d
    }()

    func path(_ name: String) -> VFSPath { .local(url.appendingPathComponent(name).path) }

    /// Runs a tool in `src` (zip, tar) to make an archive in the fixture folder.
    @discardableResult
    func make(_ tool: String, _ args: [String], in dir: String = "src") throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = url.appendingPathComponent(dir)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func open(_ name: String, byContent: Bool = false) async throws -> VFSPath {
        let item = try await registry.provider(for: .local).item(at: path(name))
        return try #require(try await registry.openContainer(item, byContent: byContent))
    }

    func names(_ dir: VFSPath) async throws -> [String] {
        var all: [FileItem] = []
        for try await batch in try registry.provider(for: dir.location).list(dir) { all += batch }
        return all.map(\.name).sorted()
    }

    func read(_ path: VFSPath) async throws -> Data {
        let file = try await registry.writableProvider(for: path.location).openForReading(path, bypassCache: false)
        var out = Data()
        while true {
            let chunk = try await file.read(at: Int64(out.count), count: 1 << 20)
            if chunk.isEmpty { break }
            out += chunk
        }
        return out
    }
}

@Suite struct ArchiveIndexTests {
    @Test func impliedFoldersAreAdded() {
        let index = ArchiveIndex([
            ArchiveEntry(path: "/a/b/c.txt", kind: .file, size: 3, ordinal: 0),
            ArchiveEntry(path: "/a", kind: .directory, ordinal: 1),
            ArchiveEntry(path: "/top.txt", kind: .file, size: 1, ordinal: 2),
        ])
        #expect(index.children["/"] == ["a", "top.txt"])
        #expect(index.children["/a"] == ["b"])
        #expect(index.children["/a/b"] == ["c.txt"])
        #expect(index.entry("/a")?.ordinal == 1) // the explicit entry replaces the implied one
        #expect(index.entry("/a/b")?.kind == .directory)
    }

    @Test func laterEntryReplacesEarlier() {
        let index = ArchiveIndex([
            ArchiveEntry(path: "/x.txt", kind: .file, size: 1, ordinal: 0),
            ArchiveEntry(path: "/x.txt", kind: .file, size: 2, ordinal: 1),
        ])
        #expect(index.children["/"] == ["x.txt"])
        #expect(index.entry("/x.txt")?.size == 2)
    }

    @Test func recognisedNames() {
        let b = LibArchiveBackend()
        for name in ["a.zip", "a.ZIP", "a.tar.gz", "a.tgz", "a.tar.zst", "a.gz", "a.iso", "x.tar.xz"] {
            #expect(b.recognizes(name: name), "\(name)")
        }
        for name in ["a.docx", "a.7z", "a.rar", "a.txt", "zip", ".zip", "a.jar"] {
            #expect(!b.recognizes(name: name), "\(name)")
        }
    }
}

@Suite struct ArchiveProviderTests {
    @Test func zipListsFoldersFilesAndLinks() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-r", "-y", "-q", "../a.zip", "."]) == 0)
        let root = try await f.open("a.zip")
        #expect(root.location.container == f.path("a.zip"))
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "folder", "hello.txt", "link"])
        #expect(try await f.names(root.appending("folder")) == ["big.bin", "deeper"])
        let provider = try f.registry.provider(for: root.location)
        let link = try await provider.item(at: root.appending("link"))
        #expect(link.kind == .symlink(target: .directory))
        #expect(try await provider.item(at: root.appending(".hidden")).isHidden)
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("Grüße änd ü.txt")) == Data("unicode".utf8))
        // Reopening the same archive reuses the provider.
        #expect(try await f.open("a.zip") == root)
    }

    @Test(arguments: ["a.tar", "a.tar.gz", "a.tar.bz2", "a.tar.xz", "a.tar.zst", "a.tar.lz4"])
    func tarVariants(name: String) async throws {
        let f = try Fixture()
        let flag = ["a.tar": "-cf", "a.tar.gz": "-czf", "a.tar.bz2": "-cjf", "a.tar.xz": "-cJf",
                    "a.tar.zst": "--zstd -cf", "a.tar.lz4": "--lz4 -cf"][name]!
        #expect(try f.make("/usr/bin/tar", flag.split(separator: " ").map(String.init) + ["../" + name, "."]) == 0)
        let root = try await f.open(name)
        #expect(try await f.names(root.appending("folder/deeper")) == ["deep.txt"])
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
    }

    @Test func readsOutOfOrderAndAtOffsets() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/tar", ["-czf", "../a.tgz", "."]) == 0)
        let root = try await f.open("a.tgz")
        let provider = try f.registry.writableProvider(for: root.location)
        let big = try await provider.openForReading(root.appending("folder/big.bin"), bypassCache: false)
        #expect(try await big.read(at: 1_000_000, count: 10) == Fixture.big[1_000_000..<1_000_010])
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
        #expect(try await big.read(at: 5, count: 5) == Fixture.big[5..<10]) // backwards: reopens
        #expect(try await big.read(at: Int64(Fixture.big.count - 3), count: 100) == Fixture.big.suffix(3))
    }

    @Test func singleCompressedFile() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/gzip", ["-k", "hello.txt"]) == 0)
        try FileManager.default.moveItem(at: f.url.appendingPathComponent("src/hello.txt.gz"), to: f.url.appendingPathComponent("hello.txt.gz"))
        let root = try await f.open("hello.txt.gz")
        #expect(try await f.names(root) == ["hello.txt"])
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
    }

    @Test func zipInsideZip() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "../inner.zip", "hello.txt"]) == 0)
        #expect(try f.make("/usr/bin/zip", ["-q", "outer.zip", "inner.zip"], in: ".") == 0)
        let outer = try await f.open("outer.zip")
        let innerItem = try await f.registry.provider(for: outer.location).item(at: outer.appending("inner.zip"))
        #expect(f.registry.isContainer(innerItem))
        let inner = try #require(try await f.registry.openContainer(innerItem))
        #expect(inner.location.container == outer.appending("inner.zip"))
        #expect(try await f.read(inner.appending("hello.txt")) == Data("hello".utf8))
    }

    @Test func closedContainersAreReleased() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "../inner.zip", "hello.txt"]) == 0)
        #expect(try f.make("/usr/bin/zip", ["-q", "outer.zip", "inner.zip"], in: ".") == 0)
        let outer = try await f.open("outer.zip")
        let innerItem = try await f.registry.provider(for: outer.location).item(at: outer.appending("inner.zip"))
        let inner = try #require(try await f.registry.openContainer(innerItem))
        #expect(try await f.read(inner.appending("hello.txt")) == Data("hello".utf8))
        weak var innerProvider = try f.registry.provider(for: inner.location) as? ArchiveProvider
        weak var outerProvider = try f.registry.provider(for: outer.location) as? ArchiveProvider
        #expect(innerProvider != nil)

        // Showing the outer archive keeps it; the nested one (and its temporary copy) goes.
        #expect(f.registry.closeContainers(keeping: [outer.location]) == [inner.location])
        #expect(innerProvider == nil)
        #expect(outerProvider != nil)

        // Opening it again makes a fresh provider.
        let again = try #require(try await f.registry.openContainer(innerItem))
        #expect(try await f.read(again.appending("hello.txt")) == Data("hello".utf8))
        #expect(Set(f.registry.closeContainers(keeping: [ProviderLocation.local])) == [outer.location, inner.location])
        #expect(outerProvider == nil)
    }

    @Test func byContentOpensOtherNames() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "../doc.docx", "hello.txt"]) == 0)
        let item = try await f.registry.provider(for: .local).item(at: f.path("doc.docx"))
        #expect(!f.registry.isContainer(item))
        #expect(try await f.registry.openContainer(item) == nil)
        let root = try await f.open("doc.docx", byContent: true)
        #expect(try await f.names(root) == ["hello.txt"])
        // A file that is no archive at all stays closed.
        let text = try await f.registry.provider(for: .local).item(at: .local(f.url.appendingPathComponent("src/hello.txt").path))
        #expect(try await f.registry.openContainer(text, byContent: true) == nil)
    }

    @Test func changedArchiveIsIndexedAgain() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "../a.zip", "hello.txt"]) == 0)
        let root = try await f.open("a.zip")
        #expect(try await f.names(root) == ["hello.txt"])
        #expect(try f.make("/usr/bin/zip", ["-q", "../a.zip", "folder/deeper/deep.txt"]) == 0)
        #expect(try await f.names(root) == ["folder", "hello.txt"])
    }

    @Test func encryptedEntryFailsClearly() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "-P", "secret", "../e.zip", "hello.txt"]) == 0)
        let root = try await f.open("e.zip")
        await #expect(throws: ArchiveError.passwordNeeded(archive: "e.zip")) {
            try await f.read(root.appending("hello.txt"))
        }
    }

    @Test func archivesAreReadOnly() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "../a.zip", "hello.txt"]) == 0)
        let root = try await f.open("a.zip")
        let provider = try f.registry.writableProvider(for: root.location)
        #expect(!provider.capabilities.contains(.write))
        await #expect(throws: VFSError.self) { try await provider.remove(root.appending("hello.txt")) }
    }

    @Test func testReportsDamage() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-q", "-0", "../a.zip", "folder/big.bin"]) == 0)
        let opener = ArchiveOpener()
        #expect(try await opener.test(f.path("a.zip"), registry: f.registry) { _, _ in }.isEmpty)
        // Flip bytes in the middle of the stored data: the CRC no longer matches.
        let h = try FileHandle(forWritingTo: f.url.appendingPathComponent("a.zip"))
        try h.seek(toOffset: 1_000_000)
        try h.write(contentsOf: Data([1, 2, 3, 4]))
        try h.close()
        let other = Fixture.reopen(f)
        let problems = try await opener.test(f.path("a.zip"), registry: other) { _, _ in }
        #expect(problems.count == 1)
    }
}

extension Fixture {
    /// A registry without the providers already opened, so the damaged file is indexed fresh.
    static func reopen(_ f: Fixture) -> ProviderRegistry {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }
}

/// Extracting through the copy engine, the path F5 takes out of an archive pane.
@Suite struct ArchiveExtractionTests {
    final class Monitor: TransferMonitor {
        func checkpoint() async throws {}
        func log(_ message: String) {}
        func transferred(bytes: Int64) {}
        func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .cancel }
    }

    @Test(arguments: [false, true])
    func extractFolderTree(secure: Bool) async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/tar", ["-czf", "../a.tgz", "."]) == 0)
        let root = try await f.open("a.tgz")
        let engine = SecureCopyEngine(registry: f.registry, options: SecureCopyOptions(secure: secure), monitor: Monitor())
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("out"), withIntermediateDirectories: true)
        let summary = try await engine.transfer(root.appending("folder"), to: f.path("out/folder"), mode: .copy)
        #expect(summary.failed.isEmpty)
        #expect(try Data(contentsOf: f.url.appendingPathComponent("out/folder/big.bin")) == Fixture.big)
        #expect(try Data(contentsOf: f.url.appendingPathComponent("out/folder/deeper/deep.txt")) == Data("deep".utf8))
        _ = try await engine.transfer(root.appending("link"), to: f.path("out/link"), mode: .copy)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.url.appendingPathComponent("out/link").path) == "folder")
    }
}
