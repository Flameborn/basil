// BasilOperations
//
// The single global operation queue. Every mutating action (copy, move, delete, mkdir, rename,
// pack, ...) is a QueueOperation that runs here, one at a time. Items can be paused (the running
// one stops at its next checkpoint), reordered, cancelled and removed. The queue lives only in
// memory: it does not survive app restarts.

import BasilCore
import BasilVFS
import Foundation
import Observation
import Synchronization

/// A unit of work run by the queue. `run` is called off the main actor and must call
/// `context.checkpoint()` often (for example between chunks or files), so pausing and
/// cancelling take effect promptly.
public protocol QueueOperation: Sendable {
    /// Short description shown in the queue and spoken by VoiceOver, e.g. "Copy 3 items to Documents".
    var title: String { get }
    /// Picks the sound and speech for this operation's events.
    var kind: OperationKind { get }
    func run(_ context: OperationContext) async throws
}

extension QueueOperation {
    public var kind: OperationKind { .other }
}

/// Questions an operation asks the user while it runs. The UI answers them through
/// `FileOperationQueue.promptHandler`.
public enum QueuePrompt: Sendable {
    case conflict(FileConflict)
    case unstableSource(UnstableSource)
    case itemFailed(ItemFailure)
    /// Unpack: the folder the archive would be unpacked into already exists.
    case folderExists(FolderExists)
    /// F4 on a server: the file changed there since Basil downloaded the copy being uploaded.
    case changedOnServer(ChangedOnServer)
}

public enum QueuePromptAnswer: Sendable, Equatable {
    case conflict(ConflictChoice)
    case unstableSource(UnstableSourceDecision)
    case itemFailed(ItemFailureChoice)
    /// `forAll`: the same answer for the other archives of this operation.
    case folderExists(FolderExistsChoice, forAll: Bool)
    /// true: replace the server's file with the edited copy.
    case changedOnServer(replace: Bool)
}

/// "notes.txt was changed on the server since you opened it": uploading the edited copy would
/// replace someone else's change.
public struct ChangedOnServer: Sendable, Equatable {
    public let path: VFSPath
    /// Where the file lives, e.g. "alice@example.com".
    public let server: String
    public let then: FileFingerprint
    public let now: FileFingerprint

    public init(path: VFSPath, server: String, then: FileFingerprint, now: FileFingerprint) {
        self.path = path
        self.server = server
        self.then = then
        self.now = now
    }
}

/// "photos already exists in Downloads": unpacking would put the archive's items into it.
public struct FolderExists: Sendable, Equatable {
    public let folder: VFSPath
    public let archive: VFSPath
    /// The name a new folder would get ("photos (2)").
    public let newName: String
    /// More archives follow, so "do the same for the others" makes sense.
    public let moreArchives: Bool

    public init(folder: VFSPath, archive: VFSPath, newName: String, moreArchives: Bool) {
        self.folder = folder
        self.archive = archive
        self.newName = newName
        self.moreArchives = moreArchives
    }
}

public enum FolderExistsChoice: Sendable, Equatable {
    /// Unpack into the existing folder; files that exist go through the conflict question.
    case merge
    /// Unpack into a new folder with the next free name.
    case newName
    /// Leave this archive out.
    case skip
    case cancel
}

/// One item of a copy, move or delete failed, e.g. "Cannot copy notes.txt: Permission denied".
public struct ItemFailure: Sendable, Equatable {
    public let path: VFSPath
    /// "copy", "move", "delete" or "move to the Trash".
    public let action: String
    public let reason: String

    public init(path: VFSPath, action: String, reason: String) {
        self.path = path
        self.action = action
        self.reason = reason
    }

    public var question: String { "Cannot \(action) \(path.name)" }
}

/// Total Commander's error dialog. "Skip All" skips every later failure of the same operation.
public enum ItemFailureChoice: Sendable, Equatable {
    case retry, skip, skipAll, cancel
    /// Stop and mark the operation failed with the error. Used when nobody can be asked.
    case fail
}

/// Total Commander's overwrite dialog.
public enum ConflictChoice: Sendable, Equatable {
    case overwrite, skip, rename
    case overwriteAll, overwriteAllOlder, skipAll
    case cancel
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
    /// Top-level items done and in total (for speech: "2 of 3 items copied").
    public internal(set) var itemsDone = 0
    public internal(set) var itemsTotal = 0
    /// Speed, time left and the current file of a copy, move, unpack or upload; nil for other operations.
    public internal(set) var transfer: TransferProgress?
    /// True while the operation waits for the user to answer a prompt.
    public internal(set) var isWaitingForDecision = false
    public let kind: OperationKind
    /// Called once the item has finished, failed or been cancelled (for example to put the
    /// cursor on a new folder).
    @ObservationIgnored public var whenDone: ((QueueItemState) -> Void)?

    let operation: any QueueOperation
    let gate = PauseGate()
    /// Set when the user removes the running item: it is dropped once it has stopped.
    var removeWhenStopped = false

    init(operation: any QueueOperation) {
        self.operation = operation
        title = operation.title
        kind = operation.kind
    }
}

/// Events for announcements (VoiceOver, speech, sounds).
public struct QueueEvent: Sendable, Equatable {
    public var outcome: QueueOutcome
    public var kind: OperationKind
    public var title: String
    public var done: Int
    public var total: Int
    /// The error for `.failed`, the question for `.needsDecision`.
    public var reason: String

    public init(outcome: QueueOutcome, kind: OperationKind, title: String, done: Int = 0, total: Int = 0, reason: String = "") {
        self.outcome = outcome
        self.kind = kind
        self.title = title
        self.done = done
        self.total = total
        self.reason = reason
    }
}

@MainActor
@Observable
public final class FileOperationQueue {
    public private(set) var items: [QueueItem] = []
    /// The item being run (also while it is paused).
    public private(set) var current: QueueItem?

    @ObservationIgnored public var onEvent: ((QueueEvent) -> Void)?
    /// Called when an item starts running (the progress window shows it).
    @ObservationIgnored public var onItemStarted: ((QueueItem) -> Void)?
    /// Called when the running item has finished, failed or been cancelled.
    @ObservationIgnored public var onItemStopped: ((QueueItem) -> Void)?
    /// Shows a prompt to the user and returns the answer. Without a handler, conflicts are
    /// skipped, a changing source is skipped and a failed item fails the operation.
    @ObservationIgnored public var promptHandler: ((QueueItem, QueuePrompt) async -> QueuePromptAnswer)?
    /// Called when an item waiting for a decision is cancelled or removed: the UI closes the
    /// question as if Cancel was chosen, so the operation can stop.
    @ObservationIgnored public var promptCancelHandler: ((QueueItem) -> Void)?

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
            if item.isWaitingForDecision { promptCancelHandler?(item) }
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
            if item.isWaitingForDecision { promptCancelHandler?(item) }
        } else {
            item.state = .cancelled
            item.log.append("Cancelled")
            onEvent?(event(.cancelled, item))
            item.whenDone?(item.state)
        }
    }

    private func event(_ outcome: QueueOutcome, _ item: QueueItem, reason: String = "") -> QueueEvent {
        QueueEvent(outcome: outcome, kind: item.kind, title: item.title, done: item.itemsDone,
                   total: item.itemsTotal, reason: reason)
    }

    /// Called by a running operation (through its context) to ask the user something.
    func ask(_ prompt: QueuePrompt, for item: QueueItem) async -> QueuePromptAnswer {
        item.isWaitingForDecision = true
        let question: String
        switch prompt {
        case .conflict(let c): question = "\(c.destination.name) already exists"
        case .unstableSource(let u): question = "\(u.path.name) keeps changing"
        case .itemFailed(let f): question = "\(f.question): \(f.reason)"
        case .folderExists(let f): question = "\(f.folder.name) already exists"
        case .changedOnServer(let c): question = "\(c.path.name) was changed on the server"
        }
        item.log.append("Waiting for a decision: \(question)")
        onEvent?(event(.needsDecision, item, reason: question))
        defer { item.isWaitingForDecision = false }
        guard let handler = promptHandler else {
            switch prompt {
            case .conflict: return .conflict(.skip)
            case .unstableSource: return .unstableSource(.skip)
            case .itemFailed: return .itemFailed(.fail)
            case .folderExists: return .folderExists(.newName, forAll: false)
            case .changedOnServer: return .changedOnServer(replace: false)
            }
        }
        return await handler(item, prompt)
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
        onItemStarted?(next)
    }

    private func run(_ item: QueueItem) async {
        let (updates, sink) = AsyncStream.makeStream(of: OperationContext.Update.self, bufferingPolicy: .unbounded)
        let context = OperationContext(gate: item.gate, sink: sink) { [weak self] prompt in
            guard let self else { return nil }
            return await self.ask(prompt, for: item)
        }
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
            onEvent?(event(.finished, item))
        case .failure(let error) where error is CancellationError || item.gate.isCancelled:
            item.state = .cancelled
            item.log.append("Cancelled")
            onEvent?(event(.cancelled, item))
        case .failure(let error):
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            item.state = .failed(reason)
            item.log.append("Failed: \(reason)")
            onEvent?(event(.failed, item, reason: reason))
        }
        item.whenDone?(item.state)
        if item.removeWhenStopped { items.removeAll { $0 === item } }
        current = nil
        onItemStopped?(item)
        startNextIfIdle()
    }

    private func apply(_ update: OperationContext.Update, to item: QueueItem) {
        switch update {
        case .progress(let fraction, let detail):
            item.fraction = fraction
            item.detail = detail
        case .log(let message):
            item.log.append(message)
        case .items(let done, let total):
            item.itemsDone = done
            item.itemsTotal = total
        case .transfer(let progress):
            item.transfer = progress
        }
    }
}

/// Handed to a running operation: pause/cancel checkpoints, progress and log.
public final class OperationContext: Sendable {
    enum Update: Sendable {
        case progress(Double?, String)
        case log(String)
        case items(done: Int, total: Int)
        case transfer(TransferProgress)
    }

    private let gate: PauseGate
    private let sink: AsyncStream<Update>.Continuation
    private let asker: @Sendable (QueuePrompt) async -> QueuePromptAnswer?
    private let lastProgress = Mutex<ContinuousClock.Instant?>(nil)
    private let lastTransfer = Mutex<ContinuousClock.Instant?>(nil)
    private let started = ContinuousClock.now
    /// Time spent paused or waiting for an answer, left out of `activeSeconds`.
    private let waited = Mutex<Duration>(.zero)
    private static let progressInterval: Duration = .milliseconds(100)

    init(gate: PauseGate, sink: AsyncStream<Update>.Continuation,
         asker: @escaping @Sendable (QueuePrompt) async -> QueuePromptAnswer? = { _ in nil }) {
        self.gate = gate
        self.sink = sink
        self.asker = asker
    }

    /// Asks the user (the queue item shows as waiting for a decision meanwhile). Nil when the
    /// queue is gone.
    public func ask(_ prompt: QueuePrompt) async -> QueuePromptAnswer? {
        let start = ContinuousClock.now
        defer { addWaited(since: start) }
        return await asker(prompt)
    }

    private func addWaited(since start: ContinuousClock.Instant) {
        let d = ContinuousClock.now - start
        waited.withLock { $0 += d }
    }

    /// Seconds since the operation started, without the time it was paused or waited for the user.
    public var activeSeconds: Double {
        let total = ContinuousClock.now - started - waited.withLock { $0 }
        return Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    }

    /// Publishes the transfer state (throttled like `progress`; `force` always sends).
    public func transfer(_ progress: TransferProgress, force: Bool = false) {
        let now = ContinuousClock.now
        let send = lastTransfer.withLock { last in
            if !force, let previous = last, now - previous < Self.progressInterval { return false }
            last = now
            return true
        }
        if send { sink.yield(.transfer(progress)) }
    }

    /// Top-level items done and in total, for speech and the queue list.
    public func items(done: Int, total: Int) {
        sink.yield(.items(done: done, total: total))
    }

    /// Waits while the item is paused; throws CancellationError once it is cancelled.
    public func checkpoint() async throws {
        try Task.checkCancellation()
        guard gate.isPaused else { return try await gate.waitWhilePaused() }
        let start = ContinuousClock.now
        defer { addWaited(since: start) }
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
    var isPaused: Bool { state.withLock { $0.paused } }

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
