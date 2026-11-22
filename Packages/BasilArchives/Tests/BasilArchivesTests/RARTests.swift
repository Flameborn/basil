import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// RAR archives through the UnRAR library. Basil cannot create RAR archives, so the tests use
/// libarchive's RAR test archives (Fixtures/RAR, see its README). The encrypted ones use the
/// password "password" (d.txt in the two non-solid ones has its own, "password2"); every
/// encrypted file holds "This is from x.txt".
extension Fixture {
    static let rarFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/RAR")

    /// Copies fixture archives into the fixture folder (tests may change or leave out files).
    func addRAR(_ names: String...) throws {
        for name in names {
            try FileManager.default.copyItem(at: Self.rarFixtures.appendingPathComponent(name),
                                             to: url.appendingPathComponent(name))
        }
    }

    func addRARVolumes(_ prefix: String, count: Int, digits: Int) throws {
        for i in 1...count {
            let number = String(repeating: "0", count: max(0, digits - String(i).count)) + String(i)
            try addRAR("\(prefix).part\(number).rar")
        }
    }

    func extract(_ root: VFSPath, to name: String) async throws -> TransferSummary {
        let engine = SecureCopyEngine(registry: registry, options: SecureCopyOptions(secure: true),
                                      monitor: ArchiveExtractionTests.Monitor())
        try FileManager.default.createDirectory(at: url.appendingPathComponent("out"), withIntermediateDirectories: true)
        return try await engine.transfer(root, to: path("out/\(name)"), mode: .copy)
    }
}

@Suite struct RARTests {
    @Test func recognisedNamesAndFirstVolumes() throws {
        let b = UnRARBackend()
        #expect(b.recognizes(name: "a.rar") && b.recognizes(name: "A.RAR") && b.recognizes(name: "a.part2.rar"))
        #expect(!b.recognizes(name: "a.zip") && !b.recognizes(name: "rar"))
        let f = try Fixture()
        try f.addRARVolumes("test_read_format_rar5_multiarchive", count: 3, digits: 2)
        let first = f.url.appendingPathComponent("test_read_format_rar5_multiarchive.part01.rar")
        #expect(UnRARBackend.firstVolume(of: f.url.appendingPathComponent("test_read_format_rar5_multiarchive.part03.rar")) == first)
        #expect(UnRARBackend.firstVolume(of: first) == first)
        // No first volume next to it: the file itself.
        let lone = f.url.appendingPathComponent("other.part2.rar")
        #expect(UnRARBackend.firstVolume(of: lone) == lone)
        try Data().write(to: f.url.appendingPathComponent("old.rar"))
        #expect(UnRARBackend.firstVolume(of: f.url.appendingPathComponent("old.r00")) == f.url.appendingPathComponent("old.rar"))
    }

    @Test func rar4FilesFoldersAndLinks() async throws {
        let f = try Fixture()
        try f.addRAR("test_read_format_rar.rar")
        let root = try await f.open("test_read_format_rar.rar")
        #expect(try await f.names(root) == ["test.txt", "testdir", "testemptydir", "testlink"])
        #expect(try await f.names(root.appending("testdir")) == ["test.txt"])
        #expect(try await f.names(root.appending("testemptydir")).isEmpty)
        let text = Data("test text document\r\n".utf8)
        #expect(try await f.read(root.appending("testdir/test.txt")) == text)
        #expect(try await f.read(root.appending("test.txt")) == text)
        let provider = try f.registry.writableProvider(for: root.location)
        #expect(try await provider.readSymlink(root.appending("testlink")) == "test.txt")
        #expect(try await provider.item(at: root.appending("test.txt")).permissions == 0o644)
        #expect(try await f.opener.test(f.path("test_read_format_rar.rar"), registry: f.registry) { _, _ in }.isEmpty)

        let summary = try await f.extract(root, to: "all")
        #expect(summary.failed.isEmpty)
        let out = f.url.appendingPathComponent("out/all")
        #expect(try Data(contentsOf: out.appendingPathComponent("testdir/test.txt")) == text)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("testlink").path) == "test.txt")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("testemptydir").path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test func rar5SolidReadsOutOfOrderAndAtOffsets() async throws {
        let f = try Fixture()
        try f.addRAR("test_read_format_rar5_solid.rar")
        let root = try await f.open("test_read_format_rar5_solid.rar")
        #expect(try await f.names(root) == ["test.bin", "test1.bin", "test2.bin", "test3.bin", "test4.bin", "test5.bin", "test6.bin"])
        // Read in archive order first, then backwards and at offsets: the bytes must not change.
        var whole: [String: Data] = [:]
        for name in try await f.names(root) { whole[name] = try await f.read(root.appending(name)) }
        #expect(whole["test.bin"]?.count == 1200)
        #expect(whole["test6.bin"]?.count == 4096)
        for name in whole.keys.sorted().reversed() {
            #expect(try await f.read(root.appending(name)) == whole[name])
        }
        let file = try await f.registry.writableProvider(for: root.location).openForReading(root.appending("test4.bin"), bypassCache: false)
        #expect(try await file.read(at: 3000, count: 10) == whole["test4.bin"]![3000..<3010])
        #expect(try await file.read(at: 5, count: 10) == whole["test4.bin"]![5..<15])
    }

    @Test func rar5LinksAndUnicodeNames() async throws {
        let f = try Fixture()
        try f.addRAR("test_read_format_rar5_symlink.rar", "test_read_format_rar5_hardlink.rar",
                     "test_read_format_rar5_unicode.rar", "test_read_format_rar_unicode.rar")
        let links = try await f.open("test_read_format_rar5_symlink.rar")
        let provider = try f.registry.writableProvider(for: links.location)
        #expect(try await provider.readSymlink(links.appending("symlink.txt")) == "file.txt")
        #expect(try await provider.readSymlink(links.appending("dirlink")) == "dir")
        #expect(try await provider.item(at: links.appending("dir")).kind == .directory)

        let hard = try await f.open("test_read_format_rar5_hardlink.rar")
        let data = try await f.read(hard.appending("file.txt"))
        #expect(data.count == 5)
        #expect(try await f.read(hard.appending("hardlink.txt")) == data)

        let rar5 = try await f.open("test_read_format_rar5_unicode.rar")
        #expect(try await f.names(rar5).count == 3)
        let rar4 = try await f.open("test_read_format_rar_unicode.rar")
        #expect(try await f.names(rar4) == ["abcdefghijklmnopqrsテスト.txt", "表だよ"])
        #expect(try await f.read(rar4.appending("表だよ/漢字長いファイル名long-filename-in-漢字.txt")).count == 5)
        let rar4Provider = try f.registry.writableProvider(for: rar4.location)
        #expect(try await rar4Provider.readSymlink(rar4.appending("表だよ/ファイル")) == "漢字長いファイル名long-filename-in-漢字.txt")
    }

    @Test(arguments: [("test_read_format_rar5_multiarchive", 8, 2), ("test_read_format_rar_multivolume", 4, 4)])
    func multiVolumeSetsOpenFromAnyVolume(prefix: String, count: Int, digits: Int) async throws {
        let f = try Fixture()
        try f.addRARVolumes(prefix, count: count, digits: digits)
        let last = String(repeating: "0", count: digits - String(count).count) + String(count)
        let fromFirst = try await f.open("\(prefix).part\(String(repeating: "0", count: digits - 1))1.rar")
        let fromLast = try await f.open("\(prefix).part\(last).rar")
        let first = try await f.names(fromFirst)
        #expect(!first.isEmpty)
        #expect(try await f.names(fromLast) == first)
        let problems = try await f.opener.test(f.path("\(prefix).part\(last).rar"), registry: f.registry) { _, _ in }
        #expect(problems.isEmpty)
    }

    @Test func rar5FileSplitOverVolumes() async throws {
        let f = try Fixture()
        try f.addRARVolumes("test_read_format_rar5_multiarchive", count: 8, digits: 2)
        let root = try await f.open("test_read_format_rar5_multiarchive.part01.rar")
        let folder = root.appending("home/antek/temp/build/unrar5/libarchive/bin")
        #expect(try await f.names(folder) == ["bsdcat_test", "bsdtar_test"])
        #expect(try await f.read(folder.appending("bsdtar_test")).count == 365_672)
        #expect(try await f.read(folder.appending("bsdcat_test")).count == 144_608)
    }

    @Test func aMissingVolumeIsNamed() async throws {
        let f = try Fixture()
        try f.addRARVolumes("test_read_format_rar5_multiarchive", count: 3, digits: 2)
        let name = "test_read_format_rar5_multiarchive.part01.rar"
        let missing = ArchiveError.damaged("The next volume test_read_format_rar5_multiarchive.part04.rar is missing", archive: name)
        await #expect(throws: missing) { try await f.open(name) }
        #expect(throws: missing) {
            try UnRARBackend().test(f.url.appendingPathComponent(name), byContent: false, password: nil) { _, _ in true }
        }
    }

    @Test(arguments: ["test_read_format_rar4_encrypted.rar", "test_read_format_rar5_encrypted.rar"])
    func encryptedFilesAskOnceAndAreCheckedFirst(name: String) async throws {
        let f = try Fixture()
        try f.addRAR(name)
        let passwords = ScriptedPasswords(["wrong", "password"])
        f.registry.passwords = passwords
        let root = try await f.open(name)
        #expect(try await f.names(root) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(try await f.read(root.appending("a.txt")) == Data("This is from a.txt".utf8))
        #expect(passwords.asked.withLock { $0 }.isEmpty)
        #expect(try await f.read(root.appending("b.txt")) == Data("This is from b.txt".utf8))
        #expect(try await f.read(root.appending("c.txt")) == Data("This is from c.txt".utf8))
        #expect(passwords.asked.withLock { $0 } == [false, true])
        #expect(passwords.accepted.withLock { $0 } == ["password"])
        // d.txt has another password: its read fails, nothing wrong reaches the reader.
        await #expect(throws: ArchiveError.self) { try await f.read(root.appending("d.txt")) }
        let problems = try await f.opener.test(f.path(name), registry: f.registry) { _, _ in }
        #expect(problems.count == 1)
        #expect(problems.first?.hasPrefix("d.txt: wrong password") == true)
        // With its own password, d.txt reads.
        let url = f.url.appendingPathComponent(name)
        let entries = try #require(try UnRARBackend().entries(of: url, byContent: false, password: nil))
        let session = UnRARBackend().session(for: url, byContent: false, entries: entries, password: "password2")
        #expect(try session.read(entries[3], at: 0, count: 100) == Data("This is from d.txt".utf8))
    }

    @Test(arguments: ["test_read_format_rar4_encrypted_filenames.rar", "test_read_format_rar5_encrypted_filenames.rar"])
    func encryptedNamesAskUntilTheRightPassword(name: String) async throws {
        let f = try Fixture()
        try f.addRAR(name)
        await #expect(throws: ArchiveError.passwordNeeded(archive: name)) { try await f.open(name) }
        let passwords = ScriptedPasswords(["wrong", "password"])
        f.registry.passwords = passwords
        let root = try await f.open(name)
        #expect(passwords.asked.withLock { $0 } == [false, true])
        #expect(try await f.names(root) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(try await f.read(root.appending("c.txt")) == Data("This is from c.txt".utf8))
        #expect(passwords.asked.withLock { $0 }.count == 2)
    }

    @Test(arguments: ["test_read_format_rar4_solid_encrypted.rar", "test_read_format_rar5_solid_encrypted.rar"])
    func solidEncryptedExtractsThroughTheCopyEngine(name: String) async throws {
        let f = try Fixture()
        try f.addRAR(name)
        // Without a password, a test says what it could not test instead of failing.
        let untested = try UnRARBackend().test(f.url.appendingPathComponent(name), byContent: false, password: nil) { _, _ in true }
        #expect(untested == ["a.txt", "b.txt", "c.txt", "d.txt"].map { "\($0): encrypted, not tested" })
        let passwords = ScriptedPasswords([nil, "wrong", "password"])
        f.registry.passwords = passwords
        let root = try await f.open(name)
        await #expect(throws: ArchiveError.noPassword(archive: name)) { try await f.read(root.appending("a.txt")) }
        let summary = try await f.extract(root, to: "all")
        #expect(summary.failed.isEmpty)
        for file in ["a", "b", "c", "d"] {
            let data = try Data(contentsOf: f.url.appendingPathComponent("out/all/\(file).txt"))
            #expect(data == Data("This is from \(file).txt".utf8))
        }
        // Nothing was written with the wrong password: the out folder holds only the right files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.url.appendingPathComponent("out/all").path).sorted()
            == ["a.txt", "b.txt", "c.txt", "d.txt"])
    }

    @Test func damagedDataFailsTheReadAndTheTest() async throws {
        let f = try Fixture()
        try f.addRAR("test_read_format_rar5_multiple_files.rar")
        let url = f.url.appendingPathComponent("test_read_format_rar5_multiple_files.rar")
        var bytes = try Data(contentsOf: url)
        // The packed data of the last file, well past its header.
        let offset = bytes.count - 200
        bytes[offset] ^= 0xFF
        bytes[offset + 1] ^= 0xFF
        try bytes.write(to: url)
        let root = try await f.open("test_read_format_rar5_multiple_files.rar")
        #expect(try await f.read(root.appending("test1.bin")).count == 4096)
        await #expect(throws: ArchiveError.self) { try await f.read(root.appending("test4.bin")) }
        let problems = try await f.opener.test(f.path("test_read_format_rar5_multiple_files.rar"), registry: Fixture.reopen(f)) { _, _ in }
        #expect(problems.count == 1)
        #expect(problems.first?.hasPrefix("test4.bin: ") == true)
    }

    /// UnRAR keeps its error state in a global, made per thread in Vendor/unrar: failing reads on
    /// some threads must not fail good reads on others.
    @Test func parallelReadsDoNotSeeEachOthersErrors() async throws {
        let dir = Fixture.rarFixtures
        let solid = dir.appendingPathComponent("test_read_format_rar5_solid.rar")
        let encrypted = dir.appendingPathComponent("test_read_format_rar5_encrypted.rar")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let b = UnRARBackend()
                    if i % 2 == 0 {
                        let problems = try b.test(solid, byContent: false, password: nil) { _, _ in true }
                        #expect(problems.isEmpty)
                    } else {
                        #expect(try !b.checkPassword("wrong", url: encrypted, byContent: false,
                                                     entries: try #require(try b.entries(of: encrypted, byContent: false, password: nil))))
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func rarArchivesAreReadOnly() async throws {
        let f = try Fixture()
        try f.addRAR("test_read_format_rar.rar")
        f.registry.register(writer: f.opener)
        _ = try await f.open("test_read_format_rar.rar")
        #expect(f.opener.updateRefusal(for: f.path("test_read_format_rar.rar"), registry: f.registry)
            == "test_read_format_rar.rar is a RAR archive, which Basil can only read.")
    }
}
