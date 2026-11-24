import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilOperations

struct SplitSizeTests {
    @Test func parsesTypedSizes() {
        #expect(SplitSizes.parse("1 GB", decimal: false) == .success(1 << 30))
        #expect(SplitSizes.parse("1gb", decimal: true) == .success(1_000_000_000))
        #expect(SplitSizes.parse("512 MB", decimal: false) == .success(512 << 20))
        #expect(SplitSizes.parse("1.5 kb", decimal: false) == .success(1536))
        #expect(SplitSizes.parse("1,5 KB", decimal: true) == .success(1500))
        #expect(SplitSizes.parse("4096 bytes", decimal: true) == .success(4096))
        #expect(SplitSizes.parse("700", decimal: false) == .failure(.noUnit))
        #expect(SplitSizes.parse("", decimal: false) == .failure(.empty))
        #expect(SplitSizes.parse("MB", decimal: false) == .failure(.notANumber))
        #expect(SplitSizes.parse("3 parsecs", decimal: false) == .failure(.unknownUnit("parsecs")))
        #expect(SplitSizes.presets.first { $0.id == "cd700" }?.bytes == 737_280_000)
        #expect(SplitSizes.presets.first { $0.id == "dvd" }?.bytes == 4_700_372_992)
    }

    @Test func partNames() {
        #expect(SplitFileOperation.partName("a.mkv", 1, count: 7) == "a.mkv.001")
        #expect(SplitFileOperation.partName("a.mkv", 12, count: 1200) == "a.mkv.0012")
        #expect(SplitFileOperation.partCount(size: 10, partSize: 3) == 4)
    }
}

@MainActor
@Suite final class SplitOperationTests {
    let registry: ProviderRegistry = {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }()
    let dir: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("basil-split-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("out"), withIntermediateDirectories: true)
        return u
    }()

    deinit { try? FileManager.default.removeItem(at: dir) }

    func path(_ name: String) -> VFSPath { .local(dir.appendingPathComponent(name).path) }

    func run(_ op: any QueueOperation, _ queue: FileOperationQueue = FileOperationQueue()) async -> QueueItem {
        let item = queue.add(op)
        let deadline = ContinuousClock.now + .seconds(20)
        while !item.state.isDone, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return item
    }

    var data: Data {
        var d = Data(count: 1_000_003)
        d.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 >> 3) } }
        return d
    }

    func names(_ sub: String = "out") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path).sorted()
    }

    @Test func splitAndCombineRoundTrip() async throws {
        try data.write(to: dir.appendingPathComponent("movie.mkv"))
        let split = await run(SplitFileOperation(source: path("movie.mkv"), target: path("out"), partSize: 300_000,
                                                 createSFV: true, registry: registry))
        #expect(split.state == .finished, "\(split.log)")
        #expect(try names() == ["movie.mkv.001", "movie.mkv.002", "movie.mkv.003", "movie.mkv.004", "movie.mkv.sfv"])
        let sfv = try String(contentsOf: dir.appendingPathComponent("out/movie.mkv.sfv"), encoding: .utf8)
        #expect(sfv.contains("; original-size=1000003"))
        // The SFV checks the parts with Verify Checksums too.
        let verify = await run(VerifyChecksumsOperation(checksumFiles: [path("out/movie.mkv.sfv")], registry: registry))
        #expect(verify.state == .finished, "\(verify.log)")

        let set = try await CombineFilesOperation.parts(of: path("out/movie.mkv.003"), registry: registry)
        #expect(set.parts.count == 4)
        #expect(set.outputName == "movie.mkv")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("joined"), withIntermediateDirectories: true)
        let combine = await run(CombineFilesOperation(set: set, destination: path("joined/movie.mkv"), registry: registry))
        #expect(combine.state == .finished, "\(combine.log)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("joined/movie.mkv")) == data)
        #expect(try names("joined") == ["movie.mkv"])
    }

    @Test func combineRefusesDamagedOrMissingParts() async throws {
        try data.write(to: dir.appendingPathComponent("a.bin"))
        _ = await run(SplitFileOperation(source: path("a.bin"), target: path("out"), partSize: 400_000, createSFV: true, registry: registry))
        // Damage one byte of part 2.
        let part = dir.appendingPathComponent("out/a.bin.002")
        var bytes = try Data(contentsOf: part)
        bytes[10] ^= 0xFF
        try bytes.write(to: part)
        let set = try await CombineFilesOperation.parts(of: path("out/a.bin.sfv"), registry: registry)
        let combine = await run(CombineFilesOperation(set: set, destination: path("a2.bin"), registry: registry))
        #expect(combine.state == .failed(SplitProblem.damagedPart("a.bin.002").errorDescription!))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a2.bin").path))
        #expect(try names("").filter { $0.hasPrefix(".basil-partial") }.isEmpty)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("out/a.bin.002"))
        await #expect(throws: SplitProblem.missingPart("a.bin.002")) {
            _ = try await CombineFilesOperation.parts(of: self.path("out/a.bin.001"), registry: self.registry)
        }
    }

    @Test func resplittingRemovesOldPartsAndTotalCommanderCRCWorks() async throws {
        try data.write(to: dir.appendingPathComponent("b.bin"))
        _ = await run(SplitFileOperation(source: path("b.bin"), target: path("out"), partSize: 100_000, createSFV: true, registry: registry))
        #expect(try names().count == 12)
        let again = await run(SplitFileOperation(source: path("b.bin"), target: path("out"), partSize: 500_000,
                                                 createSFV: false, registry: registry))
        #expect(again.state == .finished, "\(again.log)")
        #expect(try names() == ["b.bin.001", "b.bin.002", "b.bin.003"])

        // Total Commander's split: b.001 ... plus b.crc naming the original.
        for (i, name) in ["b.001", "b.002", "b.003"].enumerated() {
            try FileManager.default.copyItem(at: dir.appendingPathComponent("out/b.bin.00\(i + 1)"),
                                             to: dir.appendingPathComponent("out/" + name))
        }
        let crc = ChecksumAlgorithm.crc32.makeHasher()
        crc.update(data)
        try "filename=b.bin\r\nsize=\(data.count)\r\ncrc32=\(crc.finalize().uppercased())\r\n"
            .write(to: dir.appendingPathComponent("out/b.crc"), atomically: true, encoding: .utf8)
        let set = try await CombineFilesOperation.parts(of: path("out/b.002"), registry: registry)
        #expect(set.baseName == "b")
        #expect(set.outputName == "b.bin")
        let combine = await run(CombineFilesOperation(set: set, destination: path("tc.bin"), registry: registry))
        #expect(combine.state == .finished, "\(combine.log)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("tc.bin")) == data)
    }

    @Test func refusesFilesNotLargerThanAPart() async throws {
        try Data("small".utf8).write(to: dir.appendingPathComponent("s.txt"))
        let split = await run(SplitFileOperation(source: path("s.txt"), target: path("out"), partSize: 5, createSFV: true, registry: registry))
        #expect(split.state == .failed(SplitProblem.notLarger("s.txt").errorDescription!))
        #expect(try names().isEmpty)
    }

    @Test func sourceChangingDuringSplitIsSplitAgain() async throws {
        try data.write(to: dir.appendingPathComponent("grow.bin"))
        let url = dir.appendingPathComponent("grow.bin")
        // Append once, while the first split runs; the retry then sees a stable file.
        let first = dir.appendingPathComponent("out/grow.bin.001").path
        let task = Task.detached {
            let deadline = ContinuousClock.now + .seconds(10)
            while !FileManager.default.fileExists(atPath: first), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .microseconds(100))
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data(repeating: 7, count: 50_000))
            try h.close()
        }
        let split = await run(SplitFileOperation(source: path("grow.bin"), target: path("out"), partSize: 2000,
                                                 createSFV: true, unstableRetries: 3, registry: registry))
        try await task.value
        #expect(split.state == .finished, "\(split.log)")
        let set = try await CombineFilesOperation.parts(of: path("out/grow.bin.001"), registry: registry)
        let combine = await run(CombineFilesOperation(set: set, destination: path("grown.bin"), registry: registry))
        #expect(combine.state == .finished, "\(combine.log)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("grown.bin")) == (try Data(contentsOf: url)))
    }
}
