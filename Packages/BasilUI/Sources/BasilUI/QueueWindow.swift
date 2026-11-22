import AppKit
import BasilCore
import BasilOperations
import SwiftUI

/// The operation queue dialog (Cmd+J): a floating panel above the main window, so the panes stay
/// usable. Escape or the queue key closes it. In the list, Space pauses or resumes, Cmd+Up and
/// Cmd+Down move the item, and Delete cancels and removes it. The buttons and VoiceOver actions
/// do the same.
@MainActor
final class QueueWindowController: NSWindowController {
    private let queue: FileOperationQueue
    private let focus = QueueFocus()

    /// - Parameter isToggleChord: true for the chords bound to the "show queue" command, which close the panel.
    /// - Parameter announce: posts a VoiceOver announcement.
    init(queue: FileOperationQueue, isToggleChord: @escaping (KeyChord) -> Bool, announce: @escaping (String) -> Void) {
        self.queue = queue
        let panel = QueuePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Operation Queue"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.basilAutosave("BasilQueueWindow")
        panel.contentMinSize = NSSize(width: 420, height: 300)
        panel.isToggleChord = isToggleChord
        super.init(window: panel)
        let hosting = NSHostingController(rootView: QueueView(queue: queue, focus: focus, announce: announce))
        hosting.view.setAccessibilityLabel("Operation Queue")
        panel.contentViewController = hosting
        if !panel.setFrameUsingName("BasilQueueWindow") { panel.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        // Start on the running item (or the first one) so VoiceOver reads it right away.
        if focus.selection.flatMap(queue.item) == nil {
            focus.selection = (queue.current ?? queue.items.first)?.id
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focus.listFocusRequests += 1
        // On first open the SwiftUI view appears before the panel is key; ask again once it is.
        DispatchQueue.main.async { [focus] in focus.listFocusRequests += 1 }
    }
}

/// Selection and focus requests shared between the controller and the SwiftUI view.
@MainActor
@Observable
final class QueueFocus {
    var selection: QueueItem.ID?
    var listFocusRequests = 0
}

/// Closes on Escape and on the queue key (Cmd+J by default).
final class QueuePanel: NSPanel {
    var isToggleChord: (KeyChord) -> Bool = { _ in false }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let chord = KeyChord(event: event), isToggleChord(chord) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct QueueView: View {
    let queue: FileOperationQueue
    @Bindable var focus: QueueFocus
    let announce: (String) -> Void
    @FocusState private var listFocused: Bool

    private var selected: QueueItem? { focus.selection.flatMap(queue.item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(selection: $focus.selection) {
                ForEach(queue.items) { item in
                    QueueRow(item: item)
                        .tag(item.id)
                        .accessibilityActions {
                            if canPause(item) {
                                Button(item.state == .paused ? "Resume" : "Pause") { togglePause(item) }
                            }
                            Button("Move Up") { move(item, by: -1) }
                            Button("Move Down") { move(item, by: 1) }
                            Button("Remove") { remove(item) }
                        }
                }
            }
            .accessibilityLabel("Operations")
            .accessibilityIdentifier("queue.list")
            .focused($listFocused)
            .overlay {
                if queue.items.isEmpty {
                    Text("The queue is empty")
                        .foregroundStyle(Theme.secondaryTextColor)
                }
            }
            .onKeyPress(.space) {
                guard let item = selected else { return .ignored }
                togglePause(item)
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                // Arrow keys also carry .numericPad, so test only the real modifiers.
                let mods = press.modifiers.intersection([.command, .shift, .option, .control])
                guard mods == .command, let item = selected else { return .ignored }
                move(item, by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onDeleteCommand {
                if let item = selected { remove(item) }
            }

            HStack {
                Button(selected?.state == .paused ? "Resume" : "Pause") {
                    if let item = selected { togglePause(item) }
                }
                .disabled(selected.map { !canPause($0) } ?? true)
                Button("Move Up") { if let item = selected { move(item, by: -1) } }
                    .disabled(selected == nil || queue.items.first?.id == focus.selection)
                Button("Move Down") { if let item = selected { move(item, by: 1) } }
                    .disabled(selected == nil || queue.items.last?.id == focus.selection)
                Button("Remove") { if let item = selected { remove(item) } }
                    .disabled(selected == nil)
                Spacer()
                Button("Remove Finished") { queue.removeFinished() }
                    .disabled(!queue.items.contains { $0.state.isDone })
            }

            QueueLogView(item: selected)
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 300)
        .onChange(of: focus.listFocusRequests, initial: true) { listFocused = true }
    }

    private func canPause(_ item: QueueItem) -> Bool {
        switch item.state {
        case .waiting, .running, .paused: true
        default: false
        }
    }

    private func togglePause(_ item: QueueItem) {
        switch queue.togglePause(item.id) {
        case .paused: announce("Paused")
        case .running, .waiting: announce("Resumed")
        default: break
        }
    }

    private func move(_ item: QueueItem, by offset: Int) {
        if queue.move(item.id, by: offset) {
            let position = (queue.items.firstIndex { $0.id == item.id } ?? 0) + 1
            announce("Moved \(offset < 0 ? "up" : "down"), \(position) of \(queue.items.count)")
        } else {
            NSSound.beep()
        }
    }

    private func remove(_ item: QueueItem) {
        let index = queue.items.firstIndex { $0.id == item.id } ?? 0
        let wasRunning = item.id == queue.current?.id
        queue.remove(item.id)
        // Keep the cursor in the list on the neighbour (the running item stays until it has stopped).
        if !wasRunning {
            let remaining = queue.items
            focus.selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        announce(wasRunning ? "Cancelling" : "Removed")
    }
}

/// One queue entry: title, state and progress. VoiceOver reads it as one element,
/// e.g. "Copy 3 items to Documents, running, 45 percent, 12 of 40 files".
struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(statusText).foregroundStyle(Theme.secondaryTextColor)
                }
                if !item.detail.isEmpty, !item.state.isDone {
                    Text(item.detail).font(.callout).foregroundStyle(Theme.secondaryTextColor).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(spokenText)
            .accessibilityIdentifier("queue.row")
            // Outside the text element: the contrast audit treats the whole element as text, and the
            // percentage is already part of the spoken text.
            if item.state == .running || item.state == .paused {
                ProgressBar(fraction: item.fraction ?? 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    private var percent: String? {
        guard let fraction = item.fraction, item.state == .running || item.state == .paused else { return nil }
        return "\(Int((fraction * 100).rounded())) percent"
    }

    private var stateText: String {
        item.isWaitingForDecision ? "waiting for your decision" : item.state.spokenName
    }

    private var statusText: String {
        [stateText.capitalizedFirst, percent].compactMap { $0 }.joined(separator: ", ")
    }

    private var spokenText: String {
        var parts = [item.title, stateText]
        if let percent { parts.append(percent) }
        if !item.detail.isEmpty, !item.state.isDone { parts.append(item.detail) }
        return parts.joined(separator: ", ")
    }
}

/// A thin progress bar drawn from theme tokens. The system bar's track is too faint in dark mode
/// (about 1.4:1 against the panel), so this one has an outline and a fill that both reach 3:1.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.progressOutline), lineWidth: 1)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.progressFill))
                    .frame(width: width)
            }
        }
        .frame(height: 6)
    }
}

/// The selected item's log, newest last.
struct QueueLogView: View {
    let item: QueueItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(item.map { $0.log.joined(separator: "\n") } ?? "No item selected")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .accessibilityLabel("Log")
            .accessibilityIdentifier("queue.log")
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
