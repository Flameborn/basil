import AppKit
import BasilCore
import BasilOperations
import BasilVFS
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
        .copy, .move, .delete, .trash, .pack, .unpack, .testArchive, .createChecksums, .verifyChecksums, .split, .combine, .other,
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
    /// The size format of the settings (unit base), read when an item is shown.
    var sizeFormat: () -> SizeFormat = { SizeFormat() }
    /// "/Users/alice/Downloads", "/Photos on alice@example.com".
    var placeName: (VFSPath) -> String = { $0.path }

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
        let view = ProgressContent(state: state, queue: queue, placeName: { [weak self] in self?.placeName($0) ?? $0.path },
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
            // A question already on the main window would end up behind the window; it opens
            // once the question is answered instead (`promptAnswered`).
            if queue.current === item, !item.state.isDone, !item.isWaitingForDecision, !backgrounded.contains(item.id) {
                show(item)
            }
        }
    }

    func itemStopped(_ item: QueueItem) {
        backgrounded.remove(item.id)
        guard state.item === item else { return }
        hide()
        state.item = nil
    }

    /// A prompt of the item was answered: the window takes focus again, or opens when it was
    /// held back while the question was up.
    func promptAnswered(for item: QueueItem) {
        guard !item.state.isDone, queue.current === item, !backgrounded.contains(item.id) else { return }
        if isOpen {
            guard state.item === item else { return }
            window?.makeKeyAndOrderFront(nil)
        } else {
            show(item)
        }
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
        state.sizeFormat = sizeFormat()
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
    var sizeFormat = SizeFormat()
}

/// Passes the queue key (Cmd+J) to the controller.
final class ProgressPanel: NSPanel {
    var onQueueKey: (KeyChord) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let chord = KeyChord(event: event), onQueueKey(chord) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The window's content. For copies, moves, unpacking and uploads (items with `transfer`) it
/// shows TC's two bars: the current file and the total, with from and to, the file being copied,
/// bytes and files done, speed, time left and time taken. Every line is its own static text and
/// each bar a progress indicator with a label and a spoken value, so VoiceOver can read them one by
/// one.
struct ProgressContent: View {
    let state: ProgressState
    let queue: FileOperationQueue
    let placeName: (VFSPath) -> String
    let background: () -> Void
    let togglePause: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = state.item {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(status(of: item))
                    .accessibilityIdentifier("progress.status")
                if let transfer = item.transfer {
                    TransferDetails(transfer: transfer, format: state.sizeFormat, placeName: placeName,
                                    showsFileBar: transfer.filesTotal != 1)
                } else {
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
        .frame(width: 520, alignment: .leading)
    }

    private var waiting: Int { queue.items.count { $0.state == .waiting } }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down))) percent"
    }

    private func status(of item: QueueItem) -> String {
        if state.cancelling { return "Cancelling" }
        if item.isWaitingForDecision { return "Waiting for your decision" }
        let paused = item.state == .paused ? "Paused" : nil
        if let t = item.transfer {
            let phase: String? = switch t.phase {
            case .counting: "Counting files"
            case .transferring: nil
            case .rereading(let attempt): "Reading the file again, it changed during the copy (attempt \(attempt))"
            case .verifying: "Verifying the copy"
            case .finishing: "Finishing the file"
            }
            let percent = t.phase == .counting ? nil : t.fraction.map(Self.percent)
            return [paused, percent, phase].compactMap { $0 }.joined(separator: ", ").ifEmpty("Working")
        }
        let percent = item.fraction.map { "\(Int(($0 * 100).rounded())) percent" }
        return [paused, percent].compactMap { $0 }.joined(separator: ", ").ifEmpty("Working")
    }
}

/// From, to, the current file with its bar, the total bar, and speed and time.
struct TransferDetails: View {
    let transfer: TransferProgress
    let format: SizeFormat
    let placeName: (VFSPath) -> String
    let showsFileBar: Bool

    var body: some View {
        let t = transfer
        VStack(alignment: .leading, spacing: 8) {
            if t.phase == .counting {
                Text(counted)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
            } else {
                if let source = t.source {
                    detailLine("From: " + (source.parent.map(placeName) ?? source.path))
                }
                if let destination = t.destination {
                    detailLine("To: " + (destination.parent.map(placeName) ?? destination.path))
                }
                if let source = t.source {
                    Text("File: " + source.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if showsFileBar {
                    LabelledBar(label: "Current file", fraction: t.fileFraction ?? 0, value: fileValue,
                                identifier: "progress.file")
                }
                LabelledBar(label: "Total", fraction: t.fraction ?? 0, value: totalValue, identifier: "progress.total")
                Text(timing)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
                    .accessibilityIdentifier("progress.timing")
            }
        }
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.secondaryTextColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }

    private var counted: String {
        let files = transfer.filesTotal == 1 ? "1 file" : "\(transfer.filesTotal) files"
        return "Counting: \(files), \(format.string(transfer.bytesTotal))"
    }

    /// "Current file: 12 MB of 30 MB"
    private var fileValue: String {
        let t = transfer
        return "Current file: \(format.string(t.fileBytesDone)) of \(format.string(t.fileBytesTotal))"
    }

    /// "Total: 1.2 GB of 3 GB, 12 of 340 files"
    private var totalValue: String {
        let t = transfer
        var parts = ["Total: \(format.string(t.bytesDone)) of \(format.string(t.bytesTotal))"]
        if t.filesTotal > 1 { parts.append("\(t.filesDone) of \(t.filesTotal) files") }
        return parts.joined(separator: ", ")
    }

    /// "12.5 MB per second, about 2 minutes 10 seconds left, 1 minute 5 seconds so far"
    private var timing: String {
        let t = transfer
        var parts: [String] = []
        if let speed = t.bytesPerSecond {
            parts.append("\(format.string(Int64(speed.rounded()))) per second")
        } else {
            parts.append("Measuring speed")
        }
        if let left = t.secondsLeft {
            let words = TransferEstimator.describe(secondsLeft: left)
            parts.append(parts.isEmpty ? words : words.prefix(1).lowercased() + words.dropFirst())
        }
        parts.append(TransferEstimator.describe(elapsed: t.elapsed) + " so far")
        return parts.joined(separator: ", ")
    }
}

/// Details above a theme-drawn bar. The bar is a progress indicator named by `label` ("Total,
/// 45 percent"); the details ("Total: 1.2 GB of 3 GB, 12 of 340 files") are their own static
/// text, so VoiceOver reads them as a line.
struct LabelledBar: View {
    let label: String
    let fraction: Double
    let value: String
    var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .accessibilityIdentifier(identifier)
            ProgressBar(fraction: fraction)
                .accessibilityRepresentation {
                    SwiftUI.ProgressView(value: min(max(fraction, 0), 1))
                        .accessibilityLabel(label)
                }
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
