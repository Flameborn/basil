import CoreServices
import Dispatch
import Foundation

/// FSEvents for whole local folder trees, reported only as "something changed" (coalesced by
/// the latency). Used where any change means "read again", such as a repository's .git folder
/// for the Git column.
public enum TreeWatcher {
    public static func changes(in paths: [String], latency: TimeInterval = 0.3) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = TreeWatcherBox(continuation: continuation)
            guard !paths.isEmpty, box.start(paths: paths, latency: latency) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in box.stop() }
        }
    }
}

private final class TreeWatcherBox: @unchecked Sendable {
    // The stream is only touched on `queue`, or before start.
    let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "basil.tree.watch")
    private var stream: FSEventStreamRef?

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func start(paths: [String], latency: TimeInterval) -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<TreeWatcherBox>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<TreeWatcherBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TreeWatcherBox>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else { return false }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
