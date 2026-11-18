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
        queue.onEvent = { if case .finished(let t) = $0 { events.append(t) } }
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
        queue.onEvent = { if case .cancelled(let t) = $0 { cancelled.append(t) } }
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
        queue.onEvent = { if case .failed(let t, let r) = $0 { failures.append("\(t): \(r)") } }
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
