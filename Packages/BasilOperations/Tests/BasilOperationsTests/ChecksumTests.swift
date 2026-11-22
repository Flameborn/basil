import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilOperations

struct ChecksumAlgorithmTests {
    /// Published test vectors for "abc" (and the empty input for XXH3, from the xxHash sources).
    @Test func knownDigests() {
        func hash(_ a: ChecksumAlgorithm, _ text: String) -> String {
            let h = a.makeHasher()
            h.update(Data(text.utf8))
            return h.finalize()
        }
        #expect(hash(.crc32, "abc") == "352441c2")
        #expect(hash(.md5, "abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(hash(.sha1, "abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(hash(.sha256, "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hash(.sha3_256, "abc") == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
        #expect(hash(.blake3, "abc") == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
        #expect(hash(.xxh3, "") == "2d06800538d394c2")
        #expect(hash(.xxh128, "") == "99aa06d3014798d86001c324468d497f")
        for a in ChecksumAlgorithm.allCases { #expect(hash(a, "abc").count == a.hexLength, "\(a)") }
    }

    @Test func parsesCommonFormats() {
        let gnu = ChecksumFile.parse("""
        # comment
        900150983cd24fb0d6963f7d28e17f72  a b.txt
        D41D8CD98F00B204E9800998ECF8427E *dir/empty
        """, algorithm: nil)
        #expect(gnu.algorithm == .md5)
        #expect(gnu.entries == [.init(name: "a b.txt", hash: "900150983cd24fb0d6963f7d28e17f72"),
                                .init(name: "dir/empty", hash: "d41d8cd98f00b204e9800998ecf8427e")])
        let sfv = ChecksumFile.parse("; made by TC\nmy song.mp3 352441C2\n", algorithm: nil)
        #expect(sfv.algorithm == .crc32)
        #expect(sfv.entries == [.init(name: "my song.mp3", hash: "352441c2")])
        let bsd = ChecksumFile.parse("SHA256 (x (1).txt) = BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", algorithm: nil)
        #expect(bsd.algorithm == .sha256)
        #expect(bsd.entries.first?.name == "x (1).txt")
        let xxh = ChecksumFile.parse("XXH3_2d06800538d394c2  empty\n", algorithm: nil)
        #expect(xxh.algorithm == .xxh3)
        #expect(xxh.entries == [.init(name: "empty", hash: "2d06800538d394c2")])
        // Written lines read back.
        for a in ChecksumAlgorithm.allCases {
            let entry = ChecksumFile.Entry(name: "with space.txt", hash: String(repeating: "a", count: a.hexLength))
            let parsed = ChecksumFile.parse(ChecksumFile.contents([entry], algorithm: a), algorithm: a)
            #expect(parsed.entries == [entry], "\(a)")
        }
        #expect(ChecksumAlgorithm.isChecksumFile("x.sha256") && ChecksumAlgorithm.isChecksumFile("a.SFV"))
        #expect(!ChecksumAlgorithm.isChecksumFile("notes.txt") && !ChecksumAlgorithm.isChecksumFile(".md5"))
    }
}

@MainActor
@Suite struct ChecksumOperationTests {
    let registry: ProviderRegistry = {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }()

    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil(.seconds(20)) { item.state.isDone }
        return item
    }

    func item(_ path: VFSPath) async throws -> FileItem {
        try await registry.provider(for: path.location).item(at: path)
    }

    @Test(arguments: ChecksumAlgorithm.allCases)
    func createThenVerifyThenDetectChange(algorithm: ChecksumAlgorithm) async throws {
        let box = try Sandbox()
        try box.mkdir("sub")
        try box.write("a.txt", Data("abc".utf8))
        try box.write("sub/b.bin", Data(repeating: 7, count: 5_000_000))
        let queue = FileOperationQueue()
        let target = box.path("all.\(algorithm.fileExtension)")
        let create = CreateChecksumsOperation(items: [try await item(box.path("a.txt")), try await item(box.path("sub"))],
                                              directory: box.path(""), algorithm: algorithm, output: .single(target),
                                              registry: registry)
        #expect(await run(queue, create).state == .finished)
        let text = try String(contentsOfFile: target.path, encoding: .utf8)
        #expect(text.contains("sub/b.bin"))
        #expect(!(try box.names()).contains { $0.hasPrefix(".basil-partial-") })

        #expect(await run(queue, VerifyChecksumsOperation(checksumFiles: [target], registry: registry)).state == .finished)
        try box.write("sub/b.bin", Data(repeating: 8, count: 5_000_000))
        try FileManager.default.removeItem(atPath: box.path("a.txt").path)
        let failed = await run(queue, VerifyChecksumsOperation(checksumFiles: [target], registry: registry))
        #expect(failed.state == .failed("2 of 2 files failed"))
        #expect(failed.log.contains { $0.contains("sub/b.bin: does not match") })
        #expect(failed.log.contains { $0.contains("a.txt: missing") })
    }

    @Test func oneChecksumFilePerFile() async throws {
        let box = try Sandbox()
        try box.write("a.txt", Data("abc".utf8))
        try box.write("b.txt", Data("b".utf8))
        let queue = FileOperationQueue()
        let op = CreateChecksumsOperation(items: [try await item(box.path("a.txt")), try await item(box.path("b.txt"))],
                                          directory: box.path(""), algorithm: .sha256, output: .perFile, registry: registry)
        #expect(await run(queue, op).state == .finished)
        #expect(try box.names() == ["a.txt", "a.txt.sha256", "b.txt", "b.txt.sha256"])
        #expect(try String(contentsOfFile: box.path("a.txt.sha256").path, encoding: .utf8)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a.txt\n")
        let verify = VerifyChecksumsOperation(checksumFiles: [box.path("a.txt.sha256"), box.path("b.txt.sha256")], registry: registry)
        #expect(await run(queue, verify).state == .finished)
    }
}
