import BasilCore
import CoreServices
import Dispatch
import Foundation

/// FSEvents-based watcher for one local directory. Reports changes to direct
/// children only; anything it can't attribute precisely becomes `.reloadAll`.
enum DirectoryWatcher {
    static func stream(for directory: VFSPath, latency: TimeInterval = 0.15) -> AsyncStream<VFSChange> {
        AsyncStream { continuation in
            let box = WatcherBox(directory: directory, continuation: continuation)
            guard box.start(latency: latency) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in box.stop() }
        }
    }
}

private final class WatcherBox: @unchecked Sendable {
    // Mutable state is only touched on `queue` (callbacks) or before start / in stop.
    let directory: VFSPath
    let continuation: AsyncStream<VFSChange>.Continuation
    private let queue = DispatchQueue(label: "basil.local.watch")
    private var stream: FSEventStreamRef?
    /// The directory with symlinks resolved via realpath(3). (URL.resolvingSymlinksInPath
    /// strips "/private", which is the opposite of what FSEvents reports.)
    private lazy var resolvedDirectory: VFSPath = {
        guard let real = realpath(directory.path, nil) else { return directory }
        defer { free(real) }
        return .local(String(cString: real))
    }()

    init(directory: VFSPath, continuation: AsyncStream<VFSChange>.Continuation) {
        self.directory = directory
        self.continuation = continuation
    }

    func start(latency: TimeInterval) -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<WatcherBox>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<WatcherBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return false }
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

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        box.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let reloadFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        // FSEvents reports real paths (e.g. /private/var for /var); compare against the resolved directory.
        let resolvedDir = resolvedDirectory
        for (path, flag) in zip(paths, flags) {
            if flag & reloadFlags != 0 {
                continuation.yield(.reloadAll)
                continue
            }
            let changed = VFSPath.local(path)
            if changed.parent == resolvedDir || changed.parent == directory {
                continuation.yield(.item(directory.appending(changed.name)))
            }
        }
    }
}
