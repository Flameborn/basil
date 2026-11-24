import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilOperations

@Suite struct TransferEstimatorTests {
    /// Simulates files copied one after another: each takes `bytes / rate + overhead` seconds,
    /// sampled every 0.1 s of active time. Returns the time when the last one finished.
    @discardableResult
    func simulate(_ e: inout TransferEstimator, sizes: [Int64], rate: Double, overhead: Double,
                  start: Double = 0, startBytes: Int64 = 0) -> (time: Double, bytes: Int64) {
        var t = start
        var bytes = startBytes
        for size in sizes {
            e.fileStarted(time: t)
            let fileTime = Double(size) / rate
            // Overhead first (open, create), then the bytes.
            t += overhead
            e.record(time: t, bytes: bytes)
            var done: Int64 = 0
            while done < size {
                let step = min(size - done, Int64(rate * 0.1))
                done += step
                t += Double(step) / rate
                e.record(time: t, bytes: bytes + done)
            }
            _ = fileTime
            bytes += size
            e.fileFinished(time: t, bytes: size)
        }
        return (t, bytes)
    }

    @Test func oneBigFileAtSteadySpeed() {
        var e = TransferEstimator()
        let rate = 10_000_000.0
        var t = 0.0
        e.fileStarted(time: 0)
        var bytes: Int64 = 0
        while t < 5 {
            t += 0.1
            bytes += Int64(rate * 0.1)
            e.record(time: t, bytes: bytes)
        }
        let speed = try! #require(e.speed(at: t))
        #expect(abs(speed - rate) / rate < 0.01)
        let left = try! #require(e.secondsLeft(at: t, bytesLeft: 100_000_000, filesLeft: 1))
        #expect(abs(left - 10) < 0.2)
    }

    @Test func nothingBeforeWarmUp() {
        var e = TransferEstimator()
        e.record(time: 0, bytes: 0)
        e.record(time: 0.5, bytes: 1000)
        #expect(e.speed(at: 0.5) == nil)
        #expect(e.secondsLeft(at: 0.5, bytesLeft: 1000, filesLeft: 1) == nil)
    }

    @Test func perFileOverheadIsFittedFromMixedSizes() {
        var e = TransferEstimator()
        let rate = 5_000_000.0
        let overhead = 0.2
        let sizes: [Int64] = (0..<40).map { i in i.isMultiple(of: 2) ? 200_000 : 4_000_000 }
        let end = simulate(&e, sizes: sizes, rate: rate, overhead: overhead)
        let fitted = try! #require(e.overhead())
        #expect(abs(fitted - overhead) < 0.03)
        // 100 small files left: mostly overhead, which a byte rate alone would miss.
        let left = try! #require(e.secondsLeft(at: end.time, bytesLeft: 100 * 10_000, filesLeft: 100))
        let truth = 100 * overhead + Double(100 * 10_000) / rate
        #expect(abs(left - truth) / truth < 0.15)
    }

    @Test func bigFilesLeftAfterSmallOnesAreNotOverestimated() {
        var e = TransferEstimator()
        let rate = 20_000_000.0
        let overhead = 0.1
        var sizes: [Int64] = []
        for i in 0..<60 { sizes.append(i % 3 == 0 ? 2_000_000 : 50_000) }
        let end = simulate(&e, sizes: sizes, rate: rate, overhead: overhead)
        let left = try! #require(e.secondsLeft(at: end.time, bytesLeft: 2_000_000_000, filesLeft: 2))
        let truth = 2_000_000_000 / rate + 2 * overhead
        #expect(abs(left - truth) / truth < 0.15)
    }

    @Test func alikeSizesFallBackToTheByteRate() {
        var e = TransferEstimator()
        let end = simulate(&e, sizes: Array(repeating: 1_000_000, count: 30), rate: 10_000_000, overhead: 0.05)
        #expect(e.overhead() == nil)
        // 10 more files like these: 10 * (0.1 + 0.05) = 1.5 s.
        let left = try! #require(e.secondsLeft(at: end.time, bytesLeft: 10_000_000, filesLeft: 10))
        #expect(abs(left - 1.5) < 0.15)
    }

    @Test func words() {
        #expect(TransferEstimator.describe(secondsLeft: 3) == "Less than 5 seconds left")
        #expect(TransferEstimator.describe(secondsLeft: 61) == "About 1 minute 1 second left")
        #expect(TransferEstimator.describe(secondsLeft: 130) == "About 2 minutes 10 seconds left")
        #expect(TransferEstimator.describe(secondsLeft: 725) == "About 12 minutes left")
        #expect(TransferEstimator.describe(secondsLeft: 3 * 3600 + 5 * 60 + 40) == "About 3 hours 5 minutes left")
        #expect(TransferEstimator.describe(elapsed: 65) == "1 minute 5 seconds")
        #expect(TransferEstimator.describe(elapsed: 0) == "0 seconds")
    }
}

@MainActor
@Suite struct TransferProgressReportingTests {
    let registry: ProviderRegistry = {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }()

    @Test(arguments: [true, false])
    func countsFilesAndBytesToTheEnd(secure: Bool) async throws {
        let box = try Sandbox()
        try box.mkdir("src/inner")
        try box.mkdir("out/src")
        try box.write("src/a.bin", Data(count: 300_000))
        try box.write("src/inner/b.bin", Data(count: 2_500_000))
        try box.write("src/inner/c.bin", Data(count: 10))
        try box.write("out/src/a.bin", Data(count: 1))
        let queue = FileOperationQueue()
        queue.promptHandler = { _, _ in .conflict(.skip) }
        var seen: [TransferProgress] = []
        let item = queue.add(TransferOperation(mode: .copy, sources: [box.path("src")], target: box.path("out"),
                                               registry: registry, options: SecureCopyOptions(secure: secure)))
        let observer = Task { @MainActor in
            while !item.state.isDone {
                if let t = item.transfer { seen.append(t) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(await waitUntil { item.state.isDone })
        await observer.value
        #expect(item.state == .finished)
        let last = try #require(item.transfer)
        #expect(last.filesTotal == 3)
        #expect(last.filesDone == 3)
        #expect(last.bytesTotal == 2_800_010)
        #expect(last.bytesDone == last.bytesTotal)
        #expect(last.fraction == 1)
        // The bytes never run backwards and never pass the total.
        for (a, b) in zip(seen, seen.dropFirst()) where a.phase != .counting && b.phase != .counting {
            #expect(b.bytesDone >= a.bytesDone)
            #expect(b.bytesDone <= b.bytesTotal)
        }
    }

    @Test func folderMovedByRenameCountsAsDone() async throws {
        let box = try Sandbox()
        try box.mkdir("src/inner")
        try box.mkdir("out")
        try box.write("src/a.bin", Data(count: 1000))
        try box.write("src/inner/b.bin", Data(count: 2000))
        let queue = FileOperationQueue()
        let item = queue.add(TransferOperation(mode: .move, sources: [box.path("src")], target: box.path("out"),
                                               registry: registry, options: SecureCopyOptions(secure: true)))
        #expect(await waitUntil { item.state.isDone })
        let last = try #require(item.transfer)
        #expect(last.bytesDone == 3000 && last.bytesTotal == 3000)
        #expect(last.filesDone == 2 && last.filesTotal == 2)
    }

    @Test func currentFileIsReported() async throws {
        let box = try Sandbox()
        try box.mkdir("out")
        let a = try box.write("big.bin", Data(count: 3_000_000))
        let queue = FileOperationQueue()
        let item = queue.add(TransferOperation(mode: .copy, sources: [a], target: box.path("out"),
                                               registry: registry, options: SecureCopyOptions(secure: true)))
        #expect(await waitUntil { item.state.isDone })
        let last = try #require(item.transfer)
        #expect(last.source == a)
        #expect(last.destination == box.path("out/big.bin"))
        #expect(last.fileBytesTotal == 3_000_000)
        #expect(last.fileFraction == 1)
    }
}
