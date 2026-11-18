#if DEBUG
import AppKit
import BasilOperations

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
