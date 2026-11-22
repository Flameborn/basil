import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Synchronization
import Testing
@testable import BasilArchives

/// The 7zz built from Vendor/7zip (Vendor/7zip/build.sh, run here when it is missing).
enum SevenZipBinary {
    static let url: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Vendor").standardizedFileURL
        let binary = root.appendingPathComponent("build/7zip/7zz")
        if !FileManager.default.isExecutableFile(atPath: binary.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [root.appendingPathComponent("7zip/build.sh").path]
            try? p.run()
            p.waitUntilExit()
        }
        return binary
    }()
}

extension Fixture {
    /// A fixture whose opener also has the 7-Zip backend.
    static func withSevenZip() throws -> Fixture {
        let f = try Fixture()
        f.opener.register(SevenZipBackend(executable: SevenZipBinary.url))
        return f
    }

    /// Runs 7zz in `src` to make an archive. `password` goes in through stdin, like the backend does it.
    @discardableResult
    func sevenZip(_ args: [String], password: String? = nil, in dir: String = "src") throws -> Int32 {
        let p = Process()
        p.executableURL = SevenZipBinary.url
        p.arguments = args
        p.currentDirectoryURL = url.appendingPathComponent(dir)
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

@Suite struct SevenZipTests {
    @Test func listingParsesModesDatesAndKinds() {
        let text = """
        Path = d
        Size = 0
        Packed Size = 0
        Modified = 2026-11-22 11:18:39.7712877
        Attributes = D drwxr-xr-x
        CRC =
        Encrypted = -

        Path = d/link
        Size = 5
        Modified = 2026-01-02 03:04:05
        Attributes = A lrwxr-xr-x
        CRC = C1EBF7BA
        Encrypted = -

        Path = d/x.bin
        Size = 3
        Attributes = A -rwsr-x--T
        CRC = 0000000A
        Encrypted = +

        Path = Windows Folder
        Attributes = D
        Encrypted = -

        """
        let entries = SevenZipListing.entries(text)
        #expect(entries.map(\.path) == ["/d", "/d/link", "/d/x.bin", "/Windows Folder"])
        #expect(entries.map(\.kind) == [.directory, .symlink, .file, .directory])
        #expect(entries[0].modified?.tv_sec == 1795346319)
        #expect(entries[0].modified?.tv_nsec == 771287700)
        #expect(entries[1].crc32 == 0xC1EB_F7BA)
        #expect(entries[2].permissions == 0o5750)
        #expect(entries[2].isEncrypted)
        #expect(entries[2].storedName == "d/x.bin")
        #expect(entries[3].permissions == nil)
    }

    @Test func progressLines() {
        #expect(SevenZipBackend.progress("  45% 3 T folder/file.bin")! == (0.45, "folder/file.bin"))
        #expect(SevenZipBackend.progress(" 0%")! == (0, ""))
        #expect(SevenZipBackend.progress("Testing archive") == nil)
    }

    @Test(arguments: [true, false])
    func browseAndReadSolidAndNot(solid: Bool) async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.sevenZip(["a", "-snl", solid ? "-ms=on" : "-ms=off", "../a.7z", "."]) == 0)
        let root = try await f.open("a.7z")
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "folder", "hello.txt", "link"])
        #expect(try await f.names(root.appending("folder")) == ["big.bin", "deeper"])
        // Out of order and at offsets: each restart or skip must still give the right bytes.
        #expect(try await f.read(root.appending("folder/deeper/deep.txt")) == Data("deep".utf8))
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
        let provider = try f.registry.writableProvider(for: root.location)
        let file = try await provider.openForReading(root.appending("folder/big.bin"), bypassCache: false)
        #expect(try await file.read(at: 2_000_000, count: 10) == Fixture.big[2_000_000..<2_000_010])
        #expect(try await file.read(at: 5, count: 10) == Fixture.big[5..<15])
        #expect(try await provider.readSymlink(root.appending("link")) == "folder")
        let item = try await provider.item(at: root.appending("hello.txt"))
        let original = try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent("src/hello.txt").path)
        #expect(abs(item.modified!.timeIntervalSince(original[.modificationDate] as! Date)) < 0.001)
        #expect(item.permissions == 0o644)
    }

    @Test(arguments: [false, true])
    func extractThroughTheCopyEngine(secure: Bool) async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.sevenZip(["a", "-snl", "../a.7z", "."]) == 0)
        let root = try await f.open("a.7z")
        let engine = SecureCopyEngine(registry: f.registry, options: SecureCopyOptions(secure: secure),
                                      monitor: ArchiveExtractionTests.Monitor())
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("out"), withIntermediateDirectories: true)
        let summary = try await engine.transfer(root, to: f.path("out/all"), mode: .copy)
        #expect(summary.failed.isEmpty)
        let out = f.url.appendingPathComponent("out/all")
        #expect(try Data(contentsOf: out.appendingPathComponent("folder/big.bin")) == Fixture.big)
        #expect(try Data(contentsOf: out.appendingPathComponent("Grüße änd ü.txt")) == Data("unicode".utf8))
        #expect(try Data(contentsOf: out.appendingPathComponent(".hidden")) == Data("hidden".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("link").path) == "folder")
    }

    @Test func damagedDataFailsTheRead() async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.sevenZip(["a", "-mx=0", "../a.7z", "folder/big.bin"]) == 0)
        let h = try FileHandle(forWritingTo: f.url.appendingPathComponent("a.7z"))
        try h.seek(toOffset: 1_000_000)
        try h.write(contentsOf: Data([1, 2, 3, 4]))
        try h.close()
        let root = try await f.open("a.7z")
        await #expect(throws: ArchiveError.self) { try await f.read(root.appending("folder/big.bin")) }
        let problems = try await ArchiveOpener(backends: [SevenZipBackend(executable: SevenZipBinary.url)])
            .test(f.path("a.7z"), registry: Fixture.reopen(f)) { _, _ in }
        #expect(problems == ["folder/big.bin: CRC Failed"])
    }

    @Test func testReportsProgressAndNoProblems() async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.sevenZip(["a", "../a.7z", "."]) == 0)
        let fractions = Mutex<[Double]>([])
        let problems = try await ArchiveOpener(backends: [SevenZipBackend(executable: SevenZipBinary.url)])
            .test(f.path("a.7z"), registry: Fixture.reopen(f)) { fraction, _ in fractions.withLock { $0.append(fraction) } }
        #expect(problems.isEmpty)
        #expect(fractions.withLock { $0.last } == 1)
    }

    @Test func encryptedArchivesFailClearly() async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.sevenZip(["a", "-p", "../files.7z", "hello.txt"], password: "secret") == 0)
        #expect(try f.sevenZip(["a", "-p", "-mhe=on", "../headers.7z", "hello.txt"], password: "secret") == 0)
        let root = try await f.open("files.7z")
        #expect(try await f.names(root) == ["hello.txt"])
        await #expect(throws: ArchiveError.encrypted(entry: "hello.txt")) { try await f.read(root.appending("hello.txt")) }
        await #expect(throws: ArchiveError.encrypted(entry: "headers.7z")) { try await f.open("headers.7z") }
    }

    @Test func otherFormatsAreLeftToLibarchive() async throws {
        let f = try Fixture.withSevenZip()
        #expect(try f.make("/usr/bin/zip", ["-q", "../a.zip", "hello.txt"]) == 0)
        let backend = SevenZipBackend(executable: SevenZipBinary.url)
        #expect(try backend.entries(of: f.url.appendingPathComponent("a.zip"), byContent: true) == nil)
        #expect(try backend.entries(of: f.url.appendingPathComponent("src/hello.txt"), byContent: true) == nil)
        #expect(!backend.recognizes(name: "a.zip"))
        #expect(backend.recognizes(name: "A.7Z"))
    }
}
