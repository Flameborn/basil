import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Synchronization
import Testing
@testable import BasilArchives

/// Writing 7z (and encrypted zip) through 7zz.
@Suite struct SevenZipWriteTests {
    func create(_ f: Fixture, _ name: String, _ options: PackOptions, paths: Bool = true) async throws -> ContainerWriteResult {
        try await f.opener.create(f.path(name), options: options, changes: try await f.srcAdds(paths: paths),
                                  replacing: false, registry: f.registry, monitor: WriteMonitor())
    }

    func checkTree(_ f: Fixture, _ root: VFSPath) async throws {
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "folder", "hello.txt", "link"])
        #expect(try await f.names(root.appending("folder")) == ["big.bin", "deeper"])
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("folder/deeper/deep.txt")) == Data("deep".utf8))
        #expect(try await f.read(root.appending("Grüße änd ü.txt")) == Data("unicode".utf8))
        #expect(try await f.registry.writableProvider(for: root.location).readSymlink(root.appending("link")) == "folder")
    }

    @Test func sevenZipIsOfferedWithItsOptions() throws {
        let f = try Fixture.withSevenZip()
        let formats = f.opener.packFormats
        #expect(formats.prefix(2).map(\.id) == ["zip", "7z"])
        let sevenZip = try #require(formats.first { $0.id == "7z" })
        #expect(sevenZip.solid && sevenZip.encryption && sevenZip.nameEncryption)
        #expect(sevenZip.levels.last == .ultra)
        let zip = try #require(formats.first { $0.id == "zip" })
        #expect(zip.encryption && !zip.nameEncryption && !zip.solid)
        // Without 7zz: no 7z and no zip password.
        #expect(!Fixture.plainFormats.contains { $0.id == "7z" || $0.encryption })
    }

    @Test(arguments: [PackLevel.store, .normal, .ultra], [true, false])
    func createAndReadBack(level: PackLevel, solid: Bool) async throws {
        let f = try Fixture.withSevenZip()
        let result = try await create(f, "a.7z", PackOptions(format: "7z", level: level, solid: solid))
        #expect(result.changedSources.isEmpty)
        #expect(try f.leftovers().isEmpty)
        try await checkTree(f, try await f.open("a.7z"))
        let listing = try SevenZipTool(executable: SevenZipBinary.url).run(["l", "-slt", "-bso1", "--", f.path("a.7z").path])
        #expect(listing.stdoutText.contains("Solid = \(solid && level != .store ? "+" : "-")"))
    }

    @Test(arguments: [false, true])
    func createEncrypted(encryptNames: Bool) async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "e.7z", PackOptions(format: "7z", password: "pässword", encryptNames: encryptNames))
        // Without a password source the names can be listed only when they are not encrypted.
        let bare = Fixture.reopen(f)
        let opener = ArchiveOpener(backends: [SevenZipBackend(executable: SevenZipBinary.url)])
        bare.register(opener: opener)
        let item = try await bare.provider(for: .local).item(at: f.path("e.7z"))
        if encryptNames {
            await #expect(throws: ArchiveError.passwordNeeded(archive: "e.7z")) { try await bare.openContainer(item) }
        } else {
            let root = try #require(try await bare.openContainer(item))
            await #expect(throws: ArchiveError.passwordNeeded(archive: "e.7z")) {
                try await bare.writableProvider(for: root.location).openForReading(root.appending("hello.txt"), bypassCache: false)
            }
        }
        f.registry.passwords = ScriptedPasswords(["pässword"])
        try await checkTree(f, try await f.open("e.7z"))
    }

    @Test func encryptedZipIsAES() async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "e.zip", PackOptions(format: "zip", password: "secret"))
        let listing = try SevenZipTool(executable: SevenZipBinary.url).run(["l", "-slt", "-bso1", "--", f.path("e.zip").path])
        #expect(listing.stdoutText.contains("AES-256"))
        f.registry.passwords = ScriptedPasswords(["secret"])
        let root = try await f.open("e.zip")
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
    }

    @Test func plainZipStaysWithLibarchive() async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "p.zip", PackOptions(format: "zip"))
        // libarchive writes Finder's __MACOSX entries; 7zz would not.
        let listing = try SevenZipTool(executable: SevenZipBinary.url).run(["l", "-ba", "-slt", "-bso1", "--", f.path("p.zip").path])
        #expect(listing.stdoutText.contains("Path = hello.txt"))
        #expect(!listing.stdoutText.contains("AES"))
    }

    @Test func withoutPathsGoesThroughStaging() async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "flat.7z", PackOptions(format: "7z"), paths: false)
        let root = try await f.open("flat.7z")
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "big.bin", "deep.txt", "hello.txt", "link"])
        #expect(try await f.read(root.appending("big.bin")) == Fixture.big)
        #expect(try f.leftovers().isEmpty)
        // Dates survive the staging clone.
        let item = try await f.registry.provider(for: root.location).item(at: root.appending("deep.txt"))
        let original = try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent("src/folder/deeper/deep.txt").path)
        #expect(abs(item.modified!.timeIntervalSince(original[.modificationDate] as! Date)) < 0.001)
    }

    @Test func packFromInsideAnotherArchive() async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.make("/usr/bin/zip", ["-q", "-r", "../in.zip", "folder", "hello.txt"]) == 0)
        let zip = try await f.open("in.zip")
        var dups: [VFSPath] = [], used = Set<String>()
        let changes = try await ContainerChange.adds(for: zip.appending("folder"), at: "/folder", registry: f.registry,
                                                     duplicates: &dups, used: &used)
        _ = try await f.opener.create(f.path("x.7z"), options: PackOptions(format: "7z"), changes: changes,
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("x.7z")
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("folder/deeper/deep.txt")) == Data("deep".utf8))
    }

    @Test func onlyTheListedItemsOfAFolderGoIn() async throws {
        let f = try Fixture.withSevenZip()
        // The conflict question skipped big.bin: the folder must go in without it.
        let changes: [ContainerChange] = [
            .addDirectory(source: f.path("src/folder"), at: "/folder"),
            .addDirectory(source: f.path("src/folder/deeper"), at: "/folder/deeper"),
            .addFile(source: f.path("src/folder/deeper/deep.txt"), at: "/folder/deeper/deep.txt"),
        ]
        _ = try await f.opener.create(f.path("part.7z"), options: PackOptions(format: "7z"), changes: changes,
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("part.7z")
        #expect(try await f.names(root.appending("folder")) == ["deeper"])
    }

    @Test(arguments: [false, true])
    func updateDeletesRenamesAndAdds(encrypted: Bool) async throws {
        let f = try Fixture.withSevenZip()
        let password = encrypted ? "secret" : nil
        _ = try await create(f, "u.7z", PackOptions(format: "7z", password: password, encryptNames: encrypted))
        if encrypted { f.registry.passwords = ScriptedPasswords(["secret"]) }
        let root = try await f.open("u.7z")
        try Data("new hello".utf8).write(to: f.url.appendingPathComponent("replacement.txt"))
        try Data("added".utf8).write(to: f.url.appendingPathComponent("added.txt"))
        let changes: [ContainerChange] = [
            .delete("/folder/deeper"),
            .rename(from: "/folder", to: "/renamed"),
            .addFile(source: f.path("replacement.txt"), at: "/hello.txt"),
            .addFile(source: f.path("added.txt"), at: "/renamed/added.txt"),
            .addDirectory(source: nil, at: "/empty"),
        ]
        #expect(f.opener.updateRefusal(for: f.path("u.7z"), registry: f.registry) == nil)
        _ = try await f.opener.update(f.path("u.7z"), changes: changes, macMetadata: true, registry: f.registry, monitor: WriteMonitor())
        #expect(try f.leftovers().isEmpty)
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "empty", "hello.txt", "link", "renamed"])
        #expect(try await f.names(root.appending("renamed")) == ["added.txt", "big.bin"])
        #expect(try await f.read(root.appending("renamed/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("renamed/added.txt")) == Data("added".utf8))
        #expect(try await f.read(root.appending("hello.txt")) == Data("new hello".utf8))
        if encrypted {
            // Still encrypted, names too: listing without the password asks for it.
            let listing = try SevenZipTool(executable: SevenZipBinary.url).run(["l", "-ba", "-bso1", "--", f.path("u.7z").path])
            #expect(listing.status != 0 && listing.askedForPassword)
        }
    }

    @Test func failedUpdateLeavesTheArchiveAlone() async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "a.7z", PackOptions(format: "7z"))
        _ = try await f.open("a.7z")
        let before = try Data(contentsOf: f.url.appendingPathComponent("a.7z"))
        await #expect(throws: (any Error).self) {
            try await f.opener.update(f.path("a.7z"), changes: [.delete("/hello.txt"), .addFile(source: f.path("missing.txt"), at: "/m.txt")],
                                      macMetadata: true, registry: f.registry, monitor: WriteMonitor())
        }
        #expect(try Data(contentsOf: f.url.appendingPathComponent("a.7z")) == before)
        #expect(try f.leftovers().isEmpty)
    }

    @Test func sourceChangingWhilePackedIsReported() async throws {
        let f = try Fixture.withSevenZip()
        let big = f.url.appendingPathComponent("src/folder/big.bin")
        let appended = Mutex(false)
        let monitor = WriteMonitor { _ in
            guard !appended.withLock({ let was = $0; $0 = true; return was }) else { return }
            let h = try! FileHandle(forWritingTo: big)
            h.seekToEndOfFile()
            h.write(Data("more".utf8))
            try! h.close()
        }
        let result = try await f.opener.create(f.path("c.7z"), options: PackOptions(format: "7z"),
                                              changes: [.addFile(source: .local(big.path), at: "/big.bin")],
                                              replacing: false, registry: f.registry, monitor: monitor)
        #expect(result.changedSources.contains(.local(big.path)))
    }

    /// F4 inside a 7z archive: an edited copy elsewhere on disk replaces its entry in a subfolder.
    @Test func editedCopyReplacesItsEntry() async throws {
        let f = try Fixture.withSevenZip()
        _ = try await create(f, "a.7z", PackOptions(format: "7z"))
        let root = try await f.open("a.7z")
        let scratch = f.url.appendingPathComponent("scratch/x", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("deep.txt")
        try Data("edited".utf8).write(to: copy)
        _ = try await f.opener.update(f.path("a.7z"), changes: [.addFile(source: .local(copy.path), at: "/folder/deeper/deep.txt")],
                                      macMetadata: true, registry: f.registry, monitor: WriteMonitor())
        #expect(try await f.read(root.appending("folder/deeper/deep.txt")) == Data("edited".utf8))
        #expect(try await f.names(root.appending("folder/deeper")) == ["deep.txt"])
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "folder", "hello.txt", "link"])
        #expect(try f.leftovers().isEmpty)
    }
}

extension ArchiveOperationTests {
    @Test func packOperationWithSevenZip() async throws {
        let f = try Fixture.withSevenZip()
        let queue = FileOperationQueue()
        let op = PackOperation(jobs: [PackOperation.Job(archive: f.path("job.7z"), sources: [f.path("src/folder"), f.path("src/hello.txt")])],
                               options: PackOptions(format: "7z", level: .ultra), storePaths: true, moveSources: false,
                               unstableRetries: 1, registry: f.registry)
        #expect(await run(queue, op).state == .finished)
        let root = try await f.open("job.7z")
        #expect(try await f.names(root) == ["folder", "hello.txt"])
    }
}

extension Fixture {
    /// The formats offered without 7zz.
    static var plainFormats: [PackFormat] { ArchiveOpener().packFormats }
}
