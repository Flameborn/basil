// BasilOperations
//
// The single global operation queue. Every mutating action (copy, move, delete, mkdir, rename,
// pack, ...) is a QueueOperation that runs here, one at a time. Items can be paused (the running
// one stops at its next checkpoint), reordered, cancelled and removed. The queue lives only in
// memory: it does not survive app restarts.

import Foundation
import Observation
import Synchronization

/// A unit of work run by the queue. `run` is called off the main actor and must call
/// `context.checkpoint()` often (for example between chunks or files), so pausing and
/// cancelling take effect promptly.
public protocol QueueOperation: Sendable {
    /// Short description shown in the queue and spoken by VoiceOver, e.g. "Copy 3 items to Documents".
    var title: String { get }
    func run(_ context: OperationContext) async throws
}

public enum QueueItemState: Equatable, Sendable {
    case waiting
    case running
    /// Paused by the user. A paused running item holds the queue (it stays the current item);
    /// a paused waiting item is skipped until it is resumed.
    case paused
    case finished
    case failed(String)
    case cancelled

    public var isDone: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .waiting, .running, .paused: false
        }
    }

    /// Plain words for the list and VoiceOver.
    public var spokenName: String {
        switch self {
        case .waiting: "waiting"
        case .running: "running"
        case .paused: "paused"
        case .finished: "finished"
        case .failed(let reason): "failed, \(reason)"
        case .cancelled: "cancelled"
        }
    }
}

/// One entry in the queue, observed by the queue window.
@MainActor
@Observable
public final class QueueItem: Identifiable {
    public let id = UUID()
    public let title: String
    public internal(set) var state: QueueItemState = .waiting
    /// 0...1, or nil while the total is unknown.
    public internal(set) var fraction: Double?
    /// Current progress in words, e.g. "12 of 40 files".
    public internal(set) var detail: String = ""
    /// This item's log, oldest first.
    public internal(set) var log: [String] = []

    let operation: any QueueOperation
    let gate = PauseGate()
    /// Set when the user removes the running item: it is dropped once it has stopped.
    var removeWhenStopped = false

    init(operation: any QueueOperation) {
        self.operation = operation
        title = operation.title
    }
}

/// Events for announcements (VoiceOver, sounds).
public enum QueueEvent: Sendable {
    case finished(title: String)
    case failed(title: String, reason: String)
    case cancelled(title: String)
}

@MainActor
@Observable
public final class FileOperationQueue {
    public private(set) var items: [QueueItem] = []
    /// The item being run (also while it is paused).
    public private(set) var current: QueueItem?

    @ObservationIgnored public var onEvent: ((QueueEvent) -> Void)?

    public init() {}

    /// Adds an operation at the end. It starts right away when nothing else is running.
    @discardableResult
    public func add(_ operation: any QueueOperation) -> QueueItem {
        let item = QueueItem(operation: operation)
        items.append(item)
        item.log.append("Added")
        startNextIfIdle()
        return item
    }

    public func item(_ id: QueueItem.ID) -> QueueItem? { items.first { $0.id == id } }

    public func pause(_ id: QueueItem.ID) {
        guard let item = item(id) else { return }
        switch item.state {
        case .running:
            item.gate.setPaused(true)
            item.state = .paused
            item.log.append("Paused")
        case .waiting:
            item.state = .paused
            item.log.append("Paused")
        default: break
        }
    }

    public func resume(_ id: QueueItem.ID) {
        guard let item = item(id), item.state == .paused else { return }
        item.log.append("Resumed")
        if item === current {
            item.state = .running
            item.gate.setPaused(false)
        } else {
            item.state = .waiting
            startNextIfIdle()
        }
    }

    /// Pauses or resumes; returns the new state (nil if the item can't be paused).
    @discardableResult
    public func togglePause(_ id: QueueItem.ID) -> QueueItemState? {
        guard let item = item(id) else { return nil }
        switch item.state {
        case .paused: resume(id)
        case .running, .waiting: pause(id)
        default: return nil
        }
        return item.state
    }

    /// Removes an item. The running item is cancelled first and disappears once it has stopped.
    public func remove(_ id: QueueItem.ID) {
        guard let item = item(id) else { return }
        if item === current {
            item.removeWhenStopped = true
            item.log.append("Cancelling")
            item.gate.cancel()
        } else {
            items.removeAll { $0 === item }
        }
    }

    /// Cancels an item but keeps it in the list (with its log).
    public func cancel(_ id: QueueItem.ID) {
        guard let item = item(id), !item.state.isDone else { return }
        if item === current {
            item.log.append("Cancelling")
            item.gate.cancel()
        } else {
            item.state = .cancelled
            item.log.append("Cancelled")
            onEvent?(.cancelled(title: item.title))
        }
    }

    public func removeFinished() {
        items.removeAll { $0.state.isDone }
    }

    /// Moves an item up (negative) or down (positive). Returns false at either end.
    @discardableResult
    public func move(_ id: QueueItem.ID, by offset: Int) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + offset
        guard items.indices.contains(to) else { return false }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        return true
    }

    // MARK: Running

    private func startNextIfIdle() {
        guard current == nil, let next = items.first(where: { $0.state == .waiting }) else { return }
        current = next
        next.state = .running
        next.log.append("Started")
        Task { await self.run(next) }
    }

    private func run(_ item: QueueItem) async {
        let (updates, sink) = AsyncStream.makeStream(of: OperationContext.Update.self, bufferingPolicy: .unbounded)
        let context = OperationContext(gate: item.gate, sink: sink)
        let operation = item.operation
        let consumer = Task { @MainActor in
            for await update in updates { self.apply(update, to: item) }
        }
        let result = await Task.detached { try await operation.run(context) }.result
        sink.finish()
        await consumer.value

        switch result {
        case .success:
            item.state = .finished
            item.fraction = 1
            item.log.append("Finished")
            onEvent?(.finished(title: item.title))
        case .failure(let error) where error is CancellationError || item.gate.isCancelled:
            item.state = .cancelled
            item.log.append("Cancelled")
            onEvent?(.cancelled(title: item.title))
        case .failure(let error):
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            item.state = .failed(reason)
            item.log.append("Failed: \(reason)")
            onEvent?(.failed(title: item.title, reason: reason))
        }
        if item.removeWhenStopped { items.removeAll { $0 === item } }
        current = nil
        startNextIfIdle()
    }

    private func apply(_ update: OperationContext.Update, to item: QueueItem) {
        switch update {
        case .progress(let fraction, let detail):
            item.fraction = fraction
            item.detail = detail
        case .log(let message):
            item.log.append(message)
        }
    }
}

/// Handed to a running operation: pause/cancel checkpoints, progress and log.
public final class OperationContext: Sendable {
    enum Update: Sendable {
        case progress(Double?, String)
        case log(String)
    }

    private let gate: PauseGate
    private let sink: AsyncStream<Update>.Continuation
    private let lastProgress = Mutex<ContinuousClock.Instant?>(nil)
    private static let progressInterval: Duration = .milliseconds(100)

    init(gate: PauseGate, sink: AsyncStream<Update>.Continuation) {
        self.gate = gate
        self.sink = sink
    }

    /// Waits while the item is paused; throws CancellationError once it is cancelled.
    public func checkpoint() async throws {
        try Task.checkCancellation()
        try await gate.waitWhilePaused()
    }

    public var isCancelled: Bool { gate.isCancelled || Task.isCancelled }

    /// Reports progress. Throttled to about ten updates a second; the final update
    /// (fraction 1) always goes through.
    public func progress(_ fraction: Double?, _ detail: String) {
        let now = ContinuousClock.now
        let send = lastProgress.withLock { last in
            if fraction != 1, let previous = last, now - previous < Self.progressInterval { return false }
            last = now
            return true
        }
        if send { sink.yield(.progress(fraction, detail)) }
    }

    public func log(_ message: String) {
        sink.yield(.log(message))
    }
}

/// Pause and cancel state of one item, shared between the queue and the running operation.
final class PauseGate: Sendable {
    private struct State {
        var paused = false
        var cancelled = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func setPaused(_ paused: Bool) {
        let resumed = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.paused = paused
            guard !paused else { return [] }
            defer { s.waiters = [] }
            return s.waiters
        }
        resumed.forEach { $0.resume() }
    }

    func cancel() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.cancelled = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }

    func waitWhilePaused() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome: Result<Void, any Error>? = state.withLock { s in
                if s.cancelled { return .failure(CancellationError()) }
                if !s.paused { return .success(()) }
                s.waiters.append(continuation)
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }
}
