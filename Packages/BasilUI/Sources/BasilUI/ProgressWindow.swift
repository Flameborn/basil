import AppKit
import BasilCore
import BasilOperations
import SwiftUI

/// Total Commander's progress dialog: one window that follows the running queue item, with
/// Background, Pause and Cancel. It opens as soon as an item starts and takes keyboard (and so
/// VoiceOver) focus; Return or Background hides it and returns focus to the pane, the item keeps
/// running in the queue. Escape or Cancel cancels the item. An item sent to the background stays
/// hidden; the next item shows the window again. Quick kinds (new folder, rename, new file) show it
/// only when they are still running after a second. It is not shown while the queue panel is open.
@MainActor
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    /// Kinds that show the window at once; every other kind after `delay`.
    static let immediateKinds: Set<OperationKind> = [
        .copy, .move, .delete, .trash, .pack, .testArchive, .createChecksums, .verifyChecksums, .other,
    ]
    static let delay: Duration = .seconds(1)

    private let queue: FileOperationQueue
    private let state = ProgressState()
    private var backgrounded = Set<QueueItem.ID>()
    /// Whether the window may open at all (the setting; the queue panel being closed).
    var isAllowed: () -> Bool = { true }
    /// Gives focus back to the main window's pane.
    var returnFocus: () -> Void = {}
    /// Opens the queue panel (the queue key pressed in this window).
    var showQueue: () -> Void = {}
    var isQueueChord: (KeyChord) -> Bool = { _ in false }
    var announce: (String) -> Void = { _ in }

    init(queue: FileOperationQueue) {
        self.queue = queue
        let panel = ProgressPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.onQueueKey = { [weak self] chord in
            guard let self, isQueueChord(chord) else { return false }
            background()
            showQueue()
            return true
        }
        let view = ProgressContent(state: state, queue: queue,
                                   background: { [weak self] in self?.background() },
                                   togglePause: { [weak self] in self?.togglePause() },
                                   cancel: { [weak self] in self?.cancel() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize
        hosting.view.setAccessibilityLabel("Progress")
        panel.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isOpen: Bool { window?.isVisible == true }
    /// The item the window shows (also while it is hidden in the background).
    var shownItem: QueueItem? { isOpen ? state.item : nil }

    // MARK: Queue events

    func itemStarted(_ item: QueueItem) {
        guard !backgrounded.contains(item.id) else { return }
        if Self.immediateKinds.contains(item.kind) { return show(item) }
        Task {
            try? await Task.sleep(for: Self.delay)
            if queue.current === item, !item.state.isDone, !backgrounded.contains(item.id) { show(item) }
        }
    }

    func itemStopped(_ item: QueueItem) {
        backgrounded.remove(item.id)
        guard state.item === item else { return }
        hide()
        state.item = nil
    }

    /// A prompt of the shown item was answered (on the main window): the window takes focus again.
    func promptAnswered(for item: QueueItem) {
        guard state.item === item, isOpen, !item.state.isDone else { return }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Buttons

    func background() {
        if let item = state.item { backgrounded.insert(item.id) }
        hide()
    }

    private func togglePause() {
        guard let item = state.item else { return }
        switch queue.togglePause(item.id) {
        case .paused: announce("Paused")
        case .running, .waiting: announce("Resumed")
        default: break
        }
    }

    private func cancel() {
        guard let item = state.item, !state.cancelling else { return }
        state.cancelling = true
        queue.cancel(item.id)
    }

    // MARK: Window

    private func show(_ item: QueueItem) {
        guard isAllowed(), let window else { return }
        let first = state.item == nil && !window.isVisible
        state.item = item
        state.cancelling = false
        window.title = item.title
        if first { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        guard let window, window.isVisible else { return }
        let wasKey = window.isKeyWindow
        window.orderOut(nil)
        if wasKey { returnFocus() }
    }

    /// The close button sends the item to the background, like TC's dialog.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        background()
        return false
    }
}

/// What the window shows; observed by the SwiftUI content.
@MainActor
@Observable
final class ProgressState {
    var item: QueueItem?
    var cancelling = false
}

/// Passes the queue key (Cmd+J) to the controller.
final class ProgressPanel: NSPanel {
    var onQueueKey: (KeyChord) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let chord = KeyChord(event: event), onQueueKey(chord) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct ProgressContent: View {
    let state: ProgressState
    let queue: FileOperationQueue
    let background: () -> Void
    let togglePause: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = state.item {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(status(of: item))
                    .accessibilityIdentifier("progress.status")
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ProgressBar(fraction: item.fraction ?? 0)
                    .accessibilityRepresentation {
                        SwiftUI.ProgressView(value: item.fraction ?? 0)
                            .accessibilityLabel("Progress")
                    }
                if waiting > 0 {
                    Text(waiting == 1 ? "1 more waiting" : "\(waiting) more waiting")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                HStack {
                    Spacer()
                    Button("Background", action: background)
                        .keyboardShortcut(.defaultAction)
                    Button(item.state == .paused ? "Resume" : "Pause", action: togglePause)
                        .disabled(state.cancelling)
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(state.cancelling)
                }
            }
        }
        .padding(16)
        .frame(width: 480, alignment: .leading)
    }

    private var waiting: Int { queue.items.count { $0.state == .waiting } }

    private func status(of item: QueueItem) -> String {
        if state.cancelling { return "Cancelling" }
        if item.isWaitingForDecision { return "Waiting for your decision" }
        let percent = item.fraction.map { "\(Int(($0 * 100).rounded())) percent" }
        let paused = item.state == .paused ? "Paused" : nil
        return [paused, percent].compactMap { $0 }.joined(separator: ", ").ifEmpty("Working")
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
