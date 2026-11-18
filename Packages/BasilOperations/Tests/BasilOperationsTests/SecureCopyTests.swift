import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilOperations

// MARK: Helpers

/// A fresh temporary folder per test, removed afterwards.
final class Sandbox: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> VFSPath { .local(url.appendingPathComponent(name).path) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> VFSPath {
        let p = path(name)
        try data.write(to: URL(fileURLWithPath: p.path))
        return p
    }

    func mkdir(_ name: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    /// Names in a folder, including dot files.
    func names(_ name: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(name).path).sorted()
    }
}

func randomData(_ count: Int) -> Data {
    var d = Data(count: count)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
    return d
}

func contents(_ p: VFSPath) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: p.path)) }
func exists(_ p: VFSPath) -> Bool { var st = Darwin.stat(); return lstat(p.path, &st) == 0 }

func append(_ p: VFSPath, _ data: Data) throws {
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p.path))
    try h.seekToEnd()
    try h.write(contentsOf: data)
    try h.close()
}

func overwrite(_ p: VFSPath, at offset: UInt64, _ data: Data) throws {
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p.path))
    try h.seek(toOffset: offset)
    try h.write(contentsOf: data)
    try h.close()
}

func truncateFile(_ p: VFSPath, to length: Int64) { #expect(Darwin.truncate(p.path, off_t(length)) == 0) }

final class TestMonitor: TransferMonitor {
    private let state = Mutex<(log: [String], bytes: Int64, asked: Int, decisions: [UnstableSourceDecision])>(([], 0, 0, []))

    init(decisions: [UnstableSourceDecision] = []) {
        state.withLock { $0.decisions = decisions }
    }

    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) { state.withLock { $0.log.append(message) } }
    func transferred(bytes: Int64) { state.withLock { $0.bytes += bytes } }
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision {
        state.withLock { s in
            s.asked += 1
            return s.decisions.isEmpty ? .cancel : s.decisions.removeFirst()
        }
    }

    var asked: Int { state.withLock { $0.asked } }
    var bytes: Int64 { state.withLock { $0.bytes } }
    var log: [String] { state.withLock { $0.log } }
}

/// Runs a hook body once, on the first matching call.
final class Once: Sendable {
    private let done = Atomic<Bool>(false)
    func callAsFunction(_ body: () throws -> Void) rethrows {
        if !done.exchange(true, ordering: .relaxed) { try body() }
    }
}

let mb = 1 << 20
let local = LocalProvider()

func makeEngine(_ monitor: TestMonitor, options: SecureCopyOptions = .init(retryDelay: .milliseconds(1)),
                hooks: EngineHooks = EngineHooks()) -> SecureCopyEngine {
    let registry = ProviderRegistry()
    registry.register(local)
    return SecureCopyEngine(registry: registry, options: options, monitor: monitor, hooks: hooks)
}

func streamOnly(_ afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> EngineHooks {
    EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.stream])
}

func noPartials(_ box: Sandbox, _ folder: String = "") throws -> Bool {
    try !box.names(folder).contains { $0.hasPrefix(".basil-partial-") }
}

// MARK: Stream strategy (cross-volume path)

@Suite struct StreamCopyTests {
    @Test func copiesUnchangedSourceWithMetadata() async throws {
        let box = try Sandbox()
        let data = randomData(3 * mb + 512 * 1024)
        let src = try box.write("a.bin", data)
        #expect(setxattr(src.path, "com.basil.test", "tag", 3, 0, 0) == 0)
        #expect(chmod(src.path, 0o640) == 0)
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_100_000_000, tv_usec: 0)]
        #expect(utimes(src.path, &times) == 0)

        let monitor = TestMonitor()
        let dst = box.path("b.bin")
        let r = try await makeEngine(monitor, hooks: streamOnly()).transferFile(src, to: dst, mode: .copy, local, local)

        #expect(r.outcome == .completed && r.strategy == .stream && r.retries == 0)
        #expect(try contents(dst) == data)
        #expect(monitor.bytes == Int64(data.count))
        var st = Darwin.stat()
        lstat(dst.path, &st)
        #expect(st.st_mode & 0o7777 == 0o640)
        #expect(st.st_mtimespec.tv_sec == 1_100_000_000)
        var value = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(dst.path, "com.basil.test", &value, 8, 0, 0) == 3)
        #expect(try noPartials(box))
        #expect(exists(src))
    }

    @Test func emptyFile() async throws {
        let box = try Sandbox()
        let src = try box.write("empty", Data())
        let dst = box.path("copy")
        let r = try await makeEngine(TestMonitor(), hooks: streamOnly()).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(r.outcome == .completed)
        #expect(try contents(dst).isEmpty)
    }

    @Test func sourceAppendedDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let hooks = streamOnly { pass, index in
            // After the last (partial) chunk, so the first pass ends at the old length.
            if pass == 0, index == 3 { try! once { try append(src, randomData(mb + 512 * 1024)) } }
        }
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)

        #expect(try contents(dst) == contents(src))
        #expect(r.retries == 1)
        // Only the old partial last chunk and the new tail chunk are written again.
        #expect(r.bytesRewritten == Int64(2 * mb))
        #expect(try noPartials(box))
    }

    @Test func appendWhileReadingIsPickedUpBySamePassAndChecked() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { try! once { try append(src, randomData(mb)) } }
        }
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == contents(src))
        // The fingerprint changed, so the file is re-read once, but nothing differs.
        #expect(r.retries == 1 && r.bytesRewritten == 0)
    }

    @Test func sourceTruncatedDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(4 * mb))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { once { truncateFile(src, to: Int64(mb + 200_000)) } }
        }
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == contents(src))
        #expect(try contents(dst).count == mb + 200_000)
        #expect(r.retries == 1)
    }

    @Test func sourceTruncatedToZeroDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb))
        let once = Once()
        let hooks = streamOnly { pass, _ in if pass == 0 { once { truncateFile(src, to: 0) } } }
        let dst = box.path("b.bin")
        _ = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst).isEmpty)
    }

    @Test func sourceRewrittenInTheMiddleDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(4 * mb))
        let once = Once()
        // Chunk 1 has already been copied when chunk 2 is done; change it then.
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 2 { try! once { try overwrite(src, at: UInt64(mb + mb / 2), randomData(1000)) } }
        }
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == contents(src))
        #expect(r.retries == 1)
        #expect(r.bytesRewritten == Int64(mb))
    }

    @Test func sourceChangedDuringReRead() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb))
        let first = Once(), second = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { try! first { try append(src, randomData(1000)) } }
            if pass == 1, index == 0 { try! second { try overwrite(src, at: 10, randomData(50)) } }
        }
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == contents(src))
        #expect(r.retries == 2)
    }

    @Test func sourceReplacedByAtomicSave() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb))
        let replacement = randomData(2 * mb + 7)
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 1 {
                try! once {
                    let tmp = try box.write("tmp", replacement)
                    #expect(Darwin.rename(tmp.path, src.path) == 0)
                }
            }
        }
        let dst = box.path("b.bin")
        _ = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == replacement)
    }

    @Test func verificationPasses() async throws {
        let box = try Sandbox()
        let data = randomData(2 * mb + 3)
        let src = try box.write("a.bin", data)
        let dst = box.path("b.bin")
        let engine = makeEngine(TestMonitor(), options: .init(verifyDestination: true, retryDelay: .milliseconds(1)), hooks: streamOnly())
        let r = try await engine.transferFile(src, to: dst, mode: .copy, local, local)
        #expect(r.outcome == .completed)
        #expect(try contents(dst) == data)
    }
}

// MARK: Unstable sources (retry, then ask)

@Suite struct UnstableSourceTests {
    /// Appends to the source after the first chunk of every pass, so it never settles.
    func alwaysChanging(_ src: VFSPath) -> EngineHooks {
        streamOnly { _, index in if index == 0 { try! append(src, randomData(10)) } }
    }

    @Test func asksAfterRetriesThenSkips() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(2 * mb))
        let monitor = TestMonitor(decisions: [.skip])
        let engine = makeEngine(monitor, options: .init(unstableRetries: 2, retryDelay: .milliseconds(1)), hooks: alwaysChanging(src))
        let dst = box.path("b.bin")
        let r = try await engine.transferFile(src, to: dst, mode: .move, local, local)
        #expect(r.outcome == .skipped)
        #expect(monitor.asked == 1)
        #expect(!exists(dst))
        #expect(exists(src))
        #expect(try noPartials(box))
    }

    @Test func keepRetryingAsksAgainThenAccept() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(2 * mb))
        let monitor = TestMonitor(decisions: [.keepRetrying, .acceptLatest])
        let engine = makeEngine(monitor, options: .init(unstableRetries: 1, retryDelay: .milliseconds(1)), hooks: alwaysChanging(src))
        let dst = box.path("b.bin")
        let r = try await engine.transferFile(src, to: dst, mode: .move, local, local)
        #expect(r.outcome == .acceptedUnstable)
        #expect(monitor.asked == 2)
        #expect(exists(dst))
        // A move never removes a source whose copy was not stable.
        #expect(!r.sourceRemoved && exists(src))
        #expect(try noPartials(box))
    }

    @Test func cancelLeavesNoPartialFile() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(2 * mb))
        let monitor = TestMonitor(decisions: [.cancel])
        let engine = makeEngine(monitor, options: .init(unstableRetries: 0, retryDelay: .milliseconds(1)), hooks: alwaysChanging(src))
        await #expect(throws: CancellationError.self) {
            _ = try await engine.transferFile(src, to: box.path("b.bin"), mode: .copy, local, local)
        }
        #expect(try box.names() == ["a.bin"])
    }
}

// MARK: Clone strategy (copy on the same APFS volume)

@Suite struct CloneCopyTests {
    @Test func clonesAndKeepsMetadata() async throws {
        let box = try Sandbox()
        let data = randomData(mb + 5)
        let src = try box.write("a.bin", data)
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_200_000_000, tv_usec: 0)]
        #expect(utimes(src.path, &times) == 0)
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor()).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(r.strategy == .clone && r.outcome == .completed)
        #expect(try contents(dst) == data)
        var st = Darwin.stat()
        lstat(dst.path, &st)
        #expect(st.st_mtimespec.tv_sec == 1_200_000_000)
    }

    func cloneAfterChange(_ change: @escaping @Sendable (VFSPath) throws -> Void) async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb))
        let once = Once()
        let hooks = EngineHooks(afterChunk: nil, afterClone: { _ in try! once { try change(src) } })
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .copy, local, local)
        #expect(r.strategy == .clone && r.retries == 1)
        #expect(try contents(dst) == contents(src))
        #expect(try noPartials(box))
    }

    @Test func sourceAppendedDuringClone() async throws {
        try await cloneAfterChange { try append($0, randomData(1234)) }
    }

    @Test func sourceTruncatedDuringClone() async throws {
        try await cloneAfterChange { truncateFile($0, to: 100) }
    }

    @Test func sourceRewrittenInTheMiddleDuringClone() async throws {
        try await cloneAfterChange { try overwrite($0, at: UInt64(mb), randomData(100)) }
    }

    @Test func alwaysChangingCloneAsks() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(1000))
        let hooks = EngineHooks(afterChunk: nil, afterClone: { _ in try! append(src, randomData(1)) })
        let monitor = TestMonitor(decisions: [.skip])
        let engine = makeEngine(monitor, options: .init(unstableRetries: 2, retryDelay: .milliseconds(1)), hooks: hooks)
        let r = try await engine.transferFile(src, to: box.path("b.bin"), mode: .copy, local, local)
        #expect(r.outcome == .skipped && monitor.asked == 1)
        #expect(try box.names() == ["a.bin"])
    }
}

// MARK: Moves

@Suite struct MoveTests {
    @Test func sameVolumeMoveRenamesAndKeepsWritesFromOpenHandles() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(mb))
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
        try writer.seekToEnd()
        try writer.write(contentsOf: randomData(100)) // appended before the move

        let dst = box.path("b.bin")
        let summary = try await makeEngine(TestMonitor()).transfer(src, to: dst, mode: .move)
        #expect(summary.files == 1)
        #expect(!exists(src))

        // Appended, truncated and rewritten in the middle after the move: all of it lands in the destination.
        let tail = randomData(5000)
        try writer.write(contentsOf: tail)
        try writer.seek(toOffset: 10)
        let middle = randomData(20)
        try writer.write(contentsOf: middle)
        try writer.close()
        let moved = try contents(dst)
        #expect(moved.count == mb + 100 + 5000)
        #expect(moved.suffix(5000) == tail)
        #expect(moved.subdata(in: 10..<30) == middle)

        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: dst.path))
        try h.truncate(atOffset: 50)
        try h.close()
        #expect(try contents(dst).count == 50)
    }

    @Test func crossVolumeMoveRemovesSourceOnlyWhenStable() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(2 * mb + 10))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { try! once { try append(src, randomData(999)) } }
        }
        let expected = try contents(src)
        let dst = box.path("b.bin")
        let r = try await makeEngine(TestMonitor(), hooks: hooks).transferFile(src, to: dst, mode: .move, local, local)
        #expect(r.sourceRemoved && !exists(src))
        #expect(try contents(dst).count == expected.count + 999)
        #expect(try contents(dst).prefix(expected.count) == expected)
    }

    @Test func existingDestinationIsNotReplacedUnlessAsked() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(100))
        let dst = try box.write("b.bin", randomData(10))
        await #expect(throws: VFSError.alreadyExists(dst)) {
            _ = try await makeEngine(TestMonitor(), hooks: streamOnly()).transferFile(src, to: dst, mode: .copy, local, local)
        }
        await #expect(throws: VFSError.self) {
            _ = try await makeEngine(TestMonitor()).transfer(src, to: dst, mode: .move)
        }
        #expect(try contents(dst).count == 10 && exists(src))

        let replacing = makeEngine(TestMonitor(), options: .init(retryDelay: .milliseconds(1), replaceExisting: true), hooks: streamOnly())
        _ = try await replacing.transferFile(src, to: dst, mode: .copy, local, local)
        #expect(try contents(dst) == contents(src))
        #expect(try noPartials(box))
    }
}

// MARK: Trees

@Suite struct TreeTests {
    func makeTree(_ box: Sandbox) throws -> VFSPath {
        try box.mkdir("src/sub/deeper")
        try box.write("src/one.txt", randomData(10))
        try box.write("src/sub/two.bin", randomData(mb + 1))
        try box.write("src/sub/deeper/.hidden", randomData(3))
        #expect(symlink("sub/two.bin", box.path("src/link").path) == 0)
        #expect(chmod(box.path("src/sub").path, 0o750) == 0)
        return box.path("src")
    }

    func checkTree(_ box: Sandbox, _ root: String) throws {
        #expect(try box.names(root) == ["link", "one.txt", "sub"])
        #expect(try box.names(root + "/sub/deeper") == [".hidden"])
        #expect(try contents(box.path(root + "/sub/two.bin")).count == mb + 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.path(root + "/link").path) == "sub/two.bin")
        var st = Darwin.stat()
        lstat(box.path(root + "/sub").path, &st)
        #expect(st.st_mode & 0o7777 == 0o750)
    }

    @Test(arguments: [true, false])
    func copiesTree(streamOnly forceStream: Bool) async throws {
        let box = try Sandbox()
        let src = try makeTree(box)
        let engine = makeEngine(TestMonitor(), hooks: forceStream ? streamOnly() : EngineHooks())
        let summary = try await engine.transfer(src, to: box.path("dst"), mode: .copy)
        #expect(summary.files == 3 && summary.directories == 3 && summary.symlinks == 1)
        try checkTree(box, "dst")
        try checkTree(box, "src")
    }

    @Test func crossVolumeMoveOfTreeRemovesSources() async throws {
        let box = try Sandbox()
        let src = try makeTree(box)
        let summary = try await makeEngine(TestMonitor(), hooks: streamOnly()).transfer(src, to: box.path("dst"), mode: .move)
        #expect(summary.sourcesKept.isEmpty)
        try checkTree(box, "dst")
        #expect(!exists(src))
    }

    @Test func sameVolumeMoveOfTreeIsOneRename() async throws {
        let box = try Sandbox()
        let src = try makeTree(box)
        let summary = try await makeEngine(TestMonitor()).transfer(src, to: box.path("dst"), mode: .move)
        #expect(summary.directories == 1)
        try checkTree(box, "dst")
        #expect(!exists(src))
    }

    @Test func refusesToCopyIntoItself() async throws {
        let box = try Sandbox()
        let src = try makeTree(box)
        await #expect(throws: CopyError.intoItself(src)) {
            _ = try await makeEngine(TestMonitor()).transfer(src, to: box.path("src/sub/inner"), mode: .copy)
        }
    }
}

// MARK: Small pieces

@Suite struct EngineRuleTests {
    @Test func chunkSizeRule() {
        let m = Int64(mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 0, limit: nil) == mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 64 * m - 1, limit: nil) == mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 64 * m, limit: nil) == 4 * mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 1024 * m, limit: nil) == 4 * mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 1024 * m + 1, limit: nil) == 8 * mb)
        #expect(SecureCopyEngine.chunkSize(forFileSize: 5000 * m, limit: mb) == mb)
    }

    @Test func partialNameFitsNameLimit() {
        let long = String(repeating: "e\u{301}", count: 200) // 3 bytes each
        let name = SecureCopyEngine.partialName(for: long)
        #expect(name.hasPrefix(".basil-partial-"))
        #expect(name.utf8.count <= 255)
        #expect(SecureCopyEngine.partialName(for: "a.txt").hasSuffix("-a.txt"))
    }
}
