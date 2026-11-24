import BasilVFS
import Foundation
import Synchronization

/// Collects what a provider's watch stream yields, for the live-folder tests.
final class WatchRecorder: Sendable {
    private final class Box: Sendable { let events = Mutex<[VFSChange]>([]) }
    private let box = Box()
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<VFSChange>) {
        let box = box
        let t = Task {
            for await change in stream { box.events.withLock { $0.append(change) } }
        }
        task.withLock { $0 = t }
    }

    var count: Int { box.events.withLock { $0.count } }

    /// Waits until at least `n` events arrived (true) or the time is up (false).
    func wait(for n: Int, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if count >= n { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return count >= n
    }

    func stop() { task.withLock { $0?.cancel() } }
}
