import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// Option+F9: unpacking whole archives, with the smart "own folder" choice.
@MainActor
@Suite struct UnpackTests {
    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        let deadline = ContinuousClock.now + .seconds(20)
        while !item.state.isDone, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return item
    }

    func names(_ f: Fixture, _ sub: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: f.url.appendingPathComponent(sub).path).sorted()
    }

    func unpack(_ f: Fixture, _ archive: String, into target: String = "out", options: UnpackOperation.Options = .init(),
                queue: FileOperationQueue = FileOperationQueue()) async -> QueueItem {
        await run(queue, UnpackOperation(archives: [f.path(archive)], target: f.path(target), options: options, registry: f.registry))
    }

    @Test func folderNames() {
        #expect(UnpackOperation.folderName(for: "photos.zip") == "photos")
        #expect(UnpackOperation.folderName(for: "photos.tar.gz") == "photos")
        #expect(UnpackOperation.folderName(for: "photos.TGZ") == "photos")
        #expect(UnpackOperation.folderName(for: "set.part01.rar") == "set")
        #expect(UnpackOperation.folderName(for: "set.r00") == "set")
        #expect(UnpackOperation.folderName(for: "movie.7z.001") == "movie")
        #expect(UnpackOperation.folderName(for: "v1.2 release.zip") == "v1.2 release")
        #expect(UnpackOperation.folderName(for: ".zip") == "zip")
    }

    @Test func severalTopItemsGetTheirOwnFolder() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/tar", ["-czf", "../photos.tar.gz", "hello.txt", "folder"]) == 0)
        let item = await unpack(f, "photos.tar.gz") // "out" does not exist yet: it is created
        #expect(item.state == .finished, "\(item.log)")
        #expect(try names(f, "out") == ["photos"])
        #expect(try names(f, "out/photos") == ["folder", "hello.txt"])
        #expect(try Data(contentsOf: f.url.appendingPathComponent("out/photos/folder/big.bin")) == Fixture.big)

        // Off: everything goes straight into the target.
        let flat = await unpack(f, "photos.tar.gz", into: "flat", options: .init(ownFolder: false))
        #expect(flat.state == .finished, "\(flat.log)")
        #expect(try names(f, "flat") == ["folder", "hello.txt"])
    }

    @Test func aSingleTopFolderIsNotWrappedAgain() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-qr", "../one.zip", "folder"]) == 0)
        let item = await unpack(f, "one.zip")
        #expect(item.state == .finished, "\(item.log)")
        #expect(try names(f, "out") == ["folder"])
        #expect(try names(f, "out/folder") == ["big.bin", "deeper"])
        // A single file is not wrapped either.
        #expect(try f.make("/usr/bin/zip", ["-q", "../single.zip", "hello.txt"]) == 0)
        _ = await unpack(f, "single.zip", into: "single")
        #expect(try names(f, "single") == ["hello.txt"])
    }

    @Test func anExistingFolderIsAskedAbout() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-qr", "../photos.zip", "hello.txt", "folder"]) == 0)
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("out/photos"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: f.url.appendingPathComponent("out/photos/mine.txt"))
        let queue = FileOperationQueue()
        var asked: [FolderExists] = []
        queue.promptHandler = { _, prompt in
            if case .folderExists(let q) = prompt { asked.append(q) }
            return .folderExists(.newName, forAll: false)
        }
        let renamed = await unpack(f, "photos.zip", queue: queue)
        #expect(renamed.state == .finished, "\(renamed.log)")
        #expect(asked.map(\.folder.name) == ["photos"])
        #expect(asked.first?.newName == "photos (2)")
        #expect(try names(f, "out") == ["photos", "photos (2)"])
        #expect(try names(f, "out/photos (2)") == ["folder", "hello.txt"])

        queue.promptHandler = { _, _ in .folderExists(.merge, forAll: false) }
        let merged = await unpack(f, "photos.zip", queue: queue)
        #expect(merged.state == .finished, "\(merged.log)")
        #expect(try names(f, "out/photos") == ["folder", "hello.txt", "mine.txt"])

        queue.promptHandler = { _, _ in .folderExists(.skip, forAll: false) }
        let skipped = await unpack(f, "photos.zip", queue: queue)
        #expect(skipped.state == .finished)
        #expect(try names(f, "out") == ["photos", "photos (2)"])

        // A single top folder that exists is asked about too; a new name renames it.
        #expect(try f.make("/usr/bin/zip", ["-qr", "../one.zip", "folder"]) == 0)
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("o2/folder"), withIntermediateDirectories: true)
        queue.promptHandler = { _, _ in .folderExists(.newName, forAll: false) }
        _ = await unpack(f, "one.zip", into: "o2", queue: queue)
        #expect(try names(f, "o2") == ["folder", "folder (2)"])
        #expect(try names(f, "o2/folder (2)") == ["big.bin", "deeper"])
    }

    @Test func maskAndFlatDecideFromWhatIsUnpacked() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-qr", "../mixed.zip", "hello.txt", "folder"]) == 0)
        // Only deep.txt matches: one item at the top, so no own folder.
        let one = await unpack(f, "mixed.zip", into: "m1", options: .init(mask: "deep*"))
        #expect(one.state == .finished, "\(one.log)")
        #expect(try names(f, "m1") == ["folder"])
        #expect(try names(f, "m1/folder/deeper") == ["deep.txt"])
        // *.txt without paths: two files at the top, so they get the archive's folder.
        let flat = await unpack(f, "mixed.zip", into: "m2", options: .init(mask: "*.txt", paths: false))
        #expect(flat.state == .finished, "\(flat.log)")
        #expect(try names(f, "m2/mixed") == ["deep.txt", "hello.txt"])
    }

    @Test func deleteAfterOnlyWhenComplete() async throws {
        let f = try Fixture()
        #expect(try f.make("/usr/bin/zip", ["-qr", "../gone.zip", "hello.txt", "folder"]) == 0)
        let item = await unpack(f, "gone.zip", options: .init(deleteAfter: .permanently))
        #expect(item.state == .finished, "\(item.log)")
        #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("gone.zip").path))
        #expect(try names(f, "out/gone") == ["folder", "hello.txt"])

        // A skipped file keeps the archive.
        #expect(try f.make("/usr/bin/zip", ["-qr", "../kept.zip", "hello.txt", "folder"]) == 0)
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("k"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: f.url.appendingPathComponent("k/hello.txt"))
        let queue = FileOperationQueue()
        queue.promptHandler = { _, _ in .conflict(.skip) }
        let kept = await unpack(f, "kept.zip", into: "k", options: .init(ownFolder: false, deleteAfter: .permanently), queue: queue)
        #expect(kept.state != .finished)
        #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("kept.zip").path))
    }

    @Test func fileListsCannotBeUnpacked() async throws {
        let f = try Fixture()
        let lists = FileListOpener()
        f.registry.register(opener: lists)
        _ = try await lists.create(f.path("a.lst"), options: PackOptions(format: "lst"), changes: try await f.srcAdds(),
                                   replacing: false, registry: f.registry, monitor: WriteMonitor())
        let item = await unpack(f, "a.lst")
        #expect(item.state != .finished)
        #expect(item.log.contains { $0.contains("file list") })
        #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("out/a").path))
    }
}
