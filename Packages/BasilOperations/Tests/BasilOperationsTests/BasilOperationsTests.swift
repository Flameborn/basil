import BasilCore
import BasilVFS
import Foundation
import Synchronization
import Testing
@testable import BasilOperations

/// Records which operations ran, step by step, so tests can check order and pausing.
final class Recorder: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

/// Runs `steps` steps of `stepTime` each, with a checkpoint before every step.
struct StepOperation: QueueOperation {
    let title: String
    var steps = 5
    var stepTime: Duration = .milliseconds(20)
    var failAt: Int?
    let recorder: Recorder

    struct Failure: LocalizedError { var errorDescription: String? { "disk full" } }

    func run(_ context: OperationContext) async throws {
        for step in 0..<steps {
            try await context.checkpoint()
            if step == failAt { throw Failure() }
            recorder.add("\(title) \(step)")
            context.progress(Double(step + 1) / Double(steps), "\(step + 1) of \(steps)")
            try await Task.sleep(for: stepTime)
        }
    }
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite struct FileOperationQueueTests {
    @Test func runsItemsOneAtATimeInOrder() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        var events: [String] = []
        queue.onEvent = { if $0.outcome == .finished { events.append($0.title) } }
        let a = queue.add(StepOperation(title: "A", steps: 3, recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 3, recorder: rec))
        #expect(a.state == .running)
        #expect(b.state == .waiting)
        #expect(await waitUntil { b.state == .finished })
        #expect(rec.all == ["A 0", "A 1", "A 2", "B 0", "B 1", "B 2"])
        #expect(a.state == .finished && a.fraction == 1)
        #expect(a.detail == "3 of 3")
        #expect(events == ["A", "B"])
        #expect(queue.current == nil)
    }

    @Test func pausingTheRunningItemHoldsTheQueue() async throws {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 6, stepTime: .milliseconds(30), recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        #expect(await waitUntil { rec.count("A") >= 1 })
        queue.pause(a.id)
        #expect(a.state == .paused)
        try await Task.sleep(for: .milliseconds(100))
        let stoppedAt = rec.count("A")
        try await Task.sleep(for: .milliseconds(200))
        #expect(rec.count("A") == stoppedAt, "no progress while paused")
        #expect(rec.count("B") == 0, "the paused current item holds the queue")
        #expect(b.state == .waiting)
        queue.resume(a.id)
        #expect(a.state == .running)
        #expect(await waitUntil { b.state == .finished })
        #expect(rec.count("A") == 6)
        #expect(a.log.contains("Paused") && a.log.contains("Resumed"))
    }

    @Test func pausedWaitingItemIsSkippedUntilResumed() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 2, recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        let c = queue.add(StepOperation(title: "C", steps: 1, recorder: rec))
        queue.pause(b.id)
        #expect(await waitUntil { c.state == .finished })
        #expect(a.state == .finished)
        #expect(b.state == .paused)
        #expect(rec.count("B") == 0)
        queue.resume(b.id)
        #expect(await waitUntil { b.state == .finished })
        #expect(rec.all.last == "B 0")
    }

    @Test func movingChangesRunOrder() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 2, recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        let c = queue.add(StepOperation(title: "C", steps: 1, recorder: rec))
        #expect(queue.move(c.id, by: -1))
        #expect(queue.items.map(\.title) == ["A", "C", "B"])
        #expect(!queue.move(b.id, by: 1), "already last")
        #expect(!queue.move(a.id, by: -1), "already first")
        #expect(await waitUntil { b.state == .finished })
        #expect(rec.all.filter { !$0.hasPrefix("A") } == ["C 0", "B 0"])
    }

    @Test func removingWaitingItemDropsIt() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 2, recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        queue.remove(b.id)
        #expect(queue.items.map(\.title) == ["A"])
        #expect(await waitUntil { a.state == .finished })
        #expect(rec.count("B") == 0)
    }

    @Test func removingRunningItemCancelsItAndStartsNext() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        var cancelled: [String] = []
        queue.onEvent = { if $0.outcome == .cancelled { cancelled.append($0.title) } }
        let a = queue.add(StepOperation(title: "A", steps: 100, stepTime: .milliseconds(10), recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        #expect(await waitUntil { rec.count("A") >= 2 })
        queue.remove(a.id)
        #expect(await waitUntil { b.state == .finished })
        #expect(queue.items.map(\.title) == ["B"])
        #expect(rec.count("A") < 100)
        #expect(cancelled == ["A"])
    }

    @Test func removingPausedRunningItemCancelsIt() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 100, stepTime: .milliseconds(10), recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        #expect(await waitUntil { rec.count("A") >= 1 })
        queue.pause(a.id)
        queue.remove(a.id)
        #expect(await waitUntil { b.state == .finished })
        #expect(queue.items.count == 1)
    }

    @Test func cancelKeepsItemInList() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 100, stepTime: .milliseconds(10), recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        queue.cancel(b.id)
        #expect(b.state == .cancelled)
        #expect(await waitUntil { rec.count("A") >= 1 })
        queue.cancel(a.id)
        #expect(await waitUntil { a.state == .cancelled })
        #expect(queue.items.count == 2)
        #expect(rec.count("B") == 0)
        queue.removeFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func failureIsRecordedAndQueueContinues() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        var failures: [String] = []
        queue.onEvent = { if $0.outcome == .failed { failures.append("\($0.title): \($0.reason)") } }
        let a = queue.add(StepOperation(title: "A", steps: 3, failAt: 1, recorder: rec))
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        #expect(await waitUntil { b.state == .finished })
        #expect(a.state == .failed("disk full"))
        #expect(a.log.last == "Failed: disk full")
        #expect(failures == ["A: disk full"])
    }

    @Test func addingAfterIdleStartsRightAway() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 1, recorder: rec))
        #expect(await waitUntil { a.state == .finished })
        let b = queue.add(StepOperation(title: "B", steps: 1, recorder: rec))
        #expect(b.state == .running)
        #expect(await waitUntil { b.state == .finished })
    }

    @Test func togglePause() async {
        let rec = Recorder()
        let queue = FileOperationQueue()
        let a = queue.add(StepOperation(title: "A", steps: 50, stepTime: .milliseconds(10), recorder: rec))
        #expect(queue.togglePause(a.id) == .paused)
        #expect(queue.togglePause(a.id) == .running)
        #expect(await waitUntil { a.state == .finished })
        #expect(queue.togglePause(a.id) == nil)
    }
}

@MainActor
@Suite struct FileOperationTests {
    let registry: ProviderRegistry = {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }()

    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil { item.state.isDone }
        return item
    }

    @Test(arguments: [true, false])
    func copyAsksOnConflictAndRemembersAll(secure: Bool) async throws {
        let box = try Sandbox()
        try box.mkdir("out")
        let a = try box.write("a.txt", Data("new a".utf8))
        let b = try box.write("b.txt", Data("new b".utf8))
        let c = try box.write("c.txt", Data("new c".utf8))
        try box.write("out/a.txt", Data("old".utf8))
        try box.write("out/b.txt", Data("old".utf8))
        let queue = FileOperationQueue()
        var asked = 0
        var events: [QueueEvent] = []
        queue.onEvent = { events.append($0) }
        queue.promptHandler = { item, prompt in
            asked += 1
            #expect(item.isWaitingForDecision)
            guard case .conflict = prompt else { return .conflict(.cancel) }
            return .conflict(.overwriteAll)
        }
        let op = TransferOperation(mode: .copy, sources: [a, b, c], target: box.path("out"), registry: registry,
                                   options: SecureCopyOptions(secure: secure))
        let item = await run(queue, op)
        #expect(item.state == .finished)
        #expect(asked == 1)
        #expect(try contents(box.path("out/b.txt")) == Data("new b".utf8))
        #expect(try contents(box.path("out/c.txt")) == Data("new c".utf8))
        #expect(item.itemsDone == 3 && item.itemsTotal == 3)
        #expect(events.map(\.outcome) == [.needsDecision, .finished])
        #expect(events.last == QueueEvent(outcome: .finished, kind: .copy, title: op.title, done: 3, total: 3))
    }

    @Test func renameChoicePicksFreeNumberedName() async throws {
        let box = try Sandbox()
        try box.mkdir("out")
        let a = try box.write("a.txt", Data("new".utf8))
        try box.write("out/a.txt", Data("old".utf8))
        try box.write("out/a (2).txt", Data("old".utf8))
        let queue = FileOperationQueue()
        queue.promptHandler = { _, _ in .conflict(.rename) }
        let item = await run(queue, TransferOperation(mode: .move, sources: [a], target: box.path("out"),
                                                      registry: registry, options: .init(secure: false)))
        #expect(item.state == .finished)
        #expect(try contents(box.path("out/a (3).txt")) == Data("new".utf8))
        #expect(!exists(a))
    }

    @Test func singleSourceToNewNameAndSeveralIntoNewFolder() async throws {
        let box = try Sandbox()
        let a = try box.write("a.txt", Data("a".utf8))
        let b = try box.write("b.txt", Data("b".utf8))
        let queue = FileOperationQueue()
        _ = await run(queue, TransferOperation(mode: .copy, sources: [a], target: box.path("renamed.txt"),
                                               registry: registry, options: .init()))
        #expect(try contents(box.path("renamed.txt")) == Data("a".utf8))
        _ = await run(queue, TransferOperation(mode: .copy, sources: [a, b], target: box.path("new"),
                                               registry: registry, options: .init()))
        #expect(try box.names("new") == ["a.txt", "b.txt"])
    }

    @Test func deleteMkdirAndRename() async throws {
        let box = try Sandbox()
        try box.mkdir("tree/sub")
        try box.write("tree/sub/x", Data("x".utf8))
        try box.write("f.txt", Data("f".utf8))
        let queue = FileOperationQueue()
        var events: [QueueEvent] = []
        queue.onEvent = { events.append($0) }

        let del = await run(queue, DeleteOperation(paths: [box.path("tree"), box.path("f.txt")], toTrash: false, registry: registry))
        #expect(del.state == .finished)
        #expect(try box.names() == [])
        #expect(events.last?.kind == .delete && events.last?.done == 2)

        _ = await run(queue, MakeDirectoryOperation(path: box.path("made"), registry: registry))
        #expect(try box.names() == ["made"])
        let again = await run(queue, MakeDirectoryOperation(path: box.path("made"), registry: registry))
        if case .failed = again.state {} else { Issue.record("mkdir over an existing folder should fail") }

        _ = await run(queue, RenameOperation(source: box.path("made"), destination: box.path("Made"), registry: registry))
        #expect(try box.names() == ["Made"])
        try box.write("other", Data())
        let clash = await run(queue, RenameOperation(source: box.path("Made"), destination: box.path("other"), registry: registry))
        if case .failed = clash.state {} else { Issue.record("rename onto an existing item should fail") }
    }
}
