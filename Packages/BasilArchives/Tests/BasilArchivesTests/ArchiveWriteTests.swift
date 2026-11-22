import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilArchives

final class WriteMonitor: ContainerWriteMonitor {
    let bytes = Mutex<Int64>(0)
    let onWritten: (@Sendable (Int64) -> Void)?
    init(onWritten: (@Sendable (Int64) -> Void)? = nil) { self.onWritten = onWritten }
    func checkpoint() async throws {}
    func log(_ message: String) {}
    func written(bytes n: Int64) {
        let total = bytes.withLock { $0 += n; return $0 }
        onWritten?(total)
    }
}

extension Fixture {
    var src: VFSPath { .local(url.appendingPathComponent("src").path) }

    /// Adds for every item in src, at the archive root.
    func srcAdds(paths: Bool = true) async throws -> [ContainerChange] {
        var dups: [VFSPath] = [], used = Set<String>()
        var all: [ContainerChange] = []
        for try await batch in try registry.provider(for: .local).list(src) {
            for item in batch {
                all += try await ContainerChange.adds(for: item.path, at: "/" + item.name, paths: paths, registry: registry,
                                                      duplicates: &dups, used: &used)
            }
        }
        return all
    }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasPrefix(".basil-partial") }
    }
}

@Suite struct ArchiveWriteTests {
    @Test(arguments: LibArchiveFormats.packFormats.filter { !$0.singleFile }.map(\.id))
    func createEveryFormat(format: String) async throws {
        let f = try Fixture()
        let name = "new." + format
        let result = try await f.opener.create(f.path(name), options: PackOptions(format: format), changes: try await f.srcAdds(),
                                              replacing: false, registry: f.registry, monitor: WriteMonitor())
        #expect(result.changedSources.isEmpty)
        #expect(try f.leftovers().isEmpty)
        let root = try await f.open(name, byContent: true)
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("Grüße änd ü.txt")) == Data("unicode".utf8))
        #expect(try await f.names(root.appending("folder")) == ["big.bin", "deeper"])
    }

    @Test(arguments: ["gz", "xz", "zst"])
    func singleCompressedFile(format: String) async throws {
        let f = try Fixture()
        let source = f.src.appending("hello.txt")
        _ = try await f.opener.create(f.path("hello.txt." + format), options: PackOptions(format: format),
                                      changes: [.addFile(source: source, at: "/hello.txt")], replacing: false,
                                      registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("hello.txt." + format)
        #expect(try await f.names(root) == ["hello.txt"])
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
    }

    @Test func createDoesNotReplaceUnlessAsked() async throws {
        let f = try Fixture()
        try Data("old".utf8).write(to: f.url.appendingPathComponent("a.zip"))
        await #expect(throws: VFSError.alreadyExists(f.path("a.zip"))) {
            try await f.opener.create(f.path("a.zip"), options: PackOptions(format: "zip"), changes: try await f.srcAdds(),
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        }
        #expect(try Data(contentsOf: f.url.appendingPathComponent("a.zip")) == Data("old".utf8))
        #expect(try f.leftovers().isEmpty)
    }

    @Test func withoutPathsStoresNamesOnly() async throws {
        let f = try Fixture()
        _ = try await f.opener.create(f.path("flat.zip"), options: PackOptions(format: "zip"), changes: try await f.srcAdds(paths: false),
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("flat.zip")
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "big.bin", "deep.txt", "hello.txt", "link"])
    }

    @Test(arguments: ["zip", "tar.gz"])
    func macMetadataRoundTrips(format: String) async throws {
        let f = try Fixture()
        let file = f.url.appendingPathComponent("src/hello.txt").path
        let value = Data("basil tag".utf8)
        #expect(value.withUnsafeBytes { setxattr(file, "org.basil.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        let name = "meta." + format
        _ = try await f.opener.create(f.path(name), options: PackOptions(format: format, macMetadata: true),
                                      changes: try await f.srcAdds(), replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open(name)
        #expect(!(try await f.names(root)).contains("__MACOSX"))
        #expect(!(try await f.names(root)).contains("._hello.txt"))
        let metadata = try await f.registry.writableProvider(for: root.location).metadata(of: root.appending("hello.txt"))
        #expect(metadata.extendedAttributes.contains { $0.name == "org.basil.test" && $0.value == value })

        // Off: nothing stored.
        _ = try await f.opener.create(f.path("plain." + format), options: PackOptions(format: format, macMetadata: false),
                                      changes: try await f.srcAdds(), replacing: false, registry: f.registry, monitor: WriteMonitor())
        let plain = try await f.open("plain." + format)
        let none = try await f.registry.writableProvider(for: plain.location).metadata(of: plain.appending("hello.txt"))
        #expect(none.extendedAttributes.isEmpty)
    }

    @Test(arguments: ["zip", "tar.gz", "tar.zst"])
    func updateDeletesRenamesAndAdds(format: String) async throws {
        let f = try Fixture()
        let name = "u." + format
        _ = try await f.opener.create(f.path(name), options: PackOptions(format: format), changes: try await f.srcAdds(),
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open(name)
        try Data("new hello".utf8).write(to: f.url.appendingPathComponent("replacement.txt"))
        let changes: [ContainerChange] = [
            .delete("/folder/deeper"),
            .rename(from: "/folder", to: "/renamed"),
            .addFile(source: f.path("replacement.txt"), at: "/hello.txt"),
            .addDirectory(source: nil, at: "/empty"),
        ]
        _ = try await f.opener.update(f.path(name), changes: changes, macMetadata: true, registry: f.registry, monitor: WriteMonitor())
        #expect(try f.leftovers().isEmpty)
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "empty", "hello.txt", "link", "renamed"])
        #expect(try await f.names(root.appending("renamed")) == ["big.bin"])
        #expect(try await f.read(root.appending("renamed/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("hello.txt")) == Data("new hello".utf8))
        #expect(try await f.read(root.appending("Grüße änd ü.txt")) == Data("unicode".utf8))
    }

    @Test func failedUpdateLeavesTheArchiveAlone() async throws {
        let f = try Fixture()
        _ = try await f.opener.create(f.path("a.zip"), options: PackOptions(format: "zip"), changes: try await f.srcAdds(),
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let before = try Data(contentsOf: f.url.appendingPathComponent("a.zip"))
        await #expect(throws: (any Error).self) {
            try await f.opener.update(f.path("a.zip"), changes: [.addFile(source: f.path("missing.txt"), at: "/missing.txt")],
                                      macMetadata: true, registry: f.registry, monitor: WriteMonitor())
        }
        #expect(try Data(contentsOf: f.url.appendingPathComponent("a.zip")) == before)
        #expect(try f.leftovers().isEmpty)
    }

    @Test func sourceChangingWhilePackedIsReported() async throws {
        let f = try Fixture()
        let big = f.url.appendingPathComponent("src/folder/big.bin")
        let appended = Mutex(false)
        let monitor = WriteMonitor { total in
            guard total >= 1 << 20, !appended.withLock({ let was = $0; $0 = true; return was }) else { return }
            let h = try! FileHandle(forWritingTo: big)
            h.seekToEndOfFile()
            h.write(Data("more".utf8))
            try! h.close()
        }
        let result = try await f.opener.create(f.path("c.zip"), options: PackOptions(format: "zip"),
                                              changes: [.addFile(source: .local(big.path), at: "/big.bin")],
                                              replacing: false, registry: f.registry, monitor: monitor)
        #expect(result.changedSources == [.local(big.path)])
    }

    @Test func nestedArchivesAndSingleFilesAreRefused() async throws {
        let f = try Fixture()
        #expect(f.opener.updateRefusal(for: f.path("a.zip"), registry: f.registry) == nil)
        let nested = VFSPath(location: ProviderLocation(provider: .archive, container: f.path("outer.zip")), path: "/inner.zip")
        #expect(f.opener.updateRefusal(for: nested, registry: f.registry) != nil)
    }
}
