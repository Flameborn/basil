#if DEBUG
import AppKit
import BasilCore
import BasilOperations
import BasilVFS

/// Debug builds only: a "Debug" menu that adds a fake operation to the queue, so the queue
/// window can be tried (and UI-tested) before real file operations exist.
@MainActor
enum DebugMenu {
    private static var target: DebugMenuTarget?

    static func install(queue: FileOperationQueue) {
        let target = DebugMenuTarget(queue: queue)
        Self.target = target
        let item = NSMenuItem()
        let menu = NSMenu(title: "Debug")
        let add = menu.addItem(withTitle: "Add Test Operation", action: #selector(DebugMenuTarget.addTestOperation(_:)), keyEquivalent: "")
        add.target = target
        let transfer = menu.addItem(withTitle: "Add Test Transfer", action: #selector(DebugMenuTarget.addTestTransfer(_:)), keyEquivalent: "")
        transfer.target = target
        item.submenu = menu
        NSApp.mainMenu?.addItem(item)
    }
}

@MainActor
final class DebugMenuTarget: NSObject {
    let queue: FileOperationQueue
    private var counter = 0

    init(queue: FileOperationQueue) { self.queue = queue }

    @objc func addTestOperation(_ sender: Any?) {
        counter += 1
        queue.add(TestOperation(title: "Test operation \(counter)"))
    }

    @objc func addTestTransfer(_ sender: Any?) {
        counter += 1
        queue.add(TestTransferOperation(title: "Test transfer \(counter)"))
    }
}

/// A fake copy of three 10 MB files over about 12 seconds, reporting like a real transfer
/// (current file, totals, speed and time left), for the progress window's UI test.
struct TestTransferOperation: QueueOperation {
    let title: String
    var kind: OperationKind { .copy }

    func run(_ context: OperationContext) async throws {
        let fileSize: Int64 = 10_000_000
        let names = ["first.bin", "second.bin", "third.bin"]
        let monitor = QueueTransferMonitor(context: context, registry: ProviderRegistry(),
                                           totalBytes: fileSize * Int64(names.count), totalFiles: names.count,
                                           action: "copy")
        for name in names {
            let source = VFSPath.local("/Users/test/Source/" + name)
            monitor.fileStarted(source, to: .local("/Users/test/Target/" + name), size: fileSize)
            var done: Int64 = 0
            while done < fileSize {
                try await context.checkpoint()
                try await Task.sleep(for: .milliseconds(100))
                let step = min(fileSize - done, 250_000)
                done += step
                monitor.transferred(bytes: step)
                monitor.fileProgress(bytes: done)
            }
            monitor.fileFinished(skipped: false)
        }
        context.progress(1, "3 items copied")
    }
}

/// Counts through 100 steps of 0.1 s (10 seconds), honouring pause and cancel.
struct TestOperation: QueueOperation {
    let title: String

    func run(_ context: OperationContext) async throws {
        let steps = 100
        for step in 1...steps {
            try await context.checkpoint()
            try await Task.sleep(for: .milliseconds(100))
            context.progress(Double(step) / Double(steps), "\(step) of \(steps) steps")
        }
        context.log("Counted \(steps) steps")
    }
}
#endif
