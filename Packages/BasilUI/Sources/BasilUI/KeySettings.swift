import AppKit
import BasilCore
import SwiftUI

/// Settings > Keys: every command in the registry with its keys. Pick a command, then remove a
/// key, record a new one (the next key pressed, whatever it is), or go back to the defaults.
/// Changes go straight to the registry, which saves them (`MainWindowController` stores
/// `CommandRegistry.keyOverrides` in `BasilSettings.keyBindings`).
@MainActor
@Observable
final class KeysModel {
    let registry: CommandRegistry
    /// Bumped on every change, so the views read the registry again.
    private(set) var version = 0
    var filter = ""
    var selection: CommandID?
    /// A key just recorded for the selected command, waiting for Assign or Cancel.
    var recorded: KeyChord?

    init(registry: CommandRegistry) {
        self.registry = registry
    }

    var commands: [CommandRegistry.Command] {
        _ = version
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return registry.allCommands }
        return registry.allCommands.filter {
            $0.title.localizedCaseInsensitiveContains(text) || keysText($0.id).localizedCaseInsensitiveContains(text)
        }
    }

    var selected: CommandRegistry.Command? { selection.flatMap(registry.command) }

    func chords(_ id: CommandID) -> [KeyChord] {
        _ = version
        return registry.chords(for: id)
    }

    func keysText(_ id: CommandID) -> String {
        let keys = chords(id)
        return keys.isEmpty ? "No key" : keys.map(\.description).joined(separator: ", ")
    }

    func hasChangedKeys(_ id: CommandID) -> Bool {
        _ = version
        return registry.hasChangedKeys(id)
    }

    var hasAnyChanges: Bool {
        _ = version
        return !registry.keyOverrides.isEmpty
    }

    /// Who has the recorded key now, if not the selected command.
    var recordedConflict: CommandRegistry.Command? {
        guard let chord = recorded, let id = selection else { return nil }
        return registry.command(using: chord, otherThan: id)
    }

    var recordedDescription: String {
        guard let chord = recorded, let command = selected else { return "" }
        if chords(command.id).contains(chord) { return "\(chord) is already a key of \(command.title)." }
        if let other = recordedConflict { return "\(chord) is used by \(other.title). Assigning it takes it away from \(other.title)." }
        return "\(chord) is not used by any command."
    }

    func record(_ chord: KeyChord) {
        recorded = chord
        announce(recordedDescription)
    }

    func assignRecorded() {
        guard let chord = recorded, let command = selected else { return }
        let other = recordedConflict
        registry.assign(chord, to: command.id)
        recorded = nil
        version += 1
        announce(other.map { "\(chord) assigned to \(command.title), removed from \($0.title)" } ?? "\(chord) assigned to \(command.title)")
    }

    func remove(_ chord: KeyChord) {
        guard let command = selected else { return }
        registry.removeKey(chord, from: command.id)
        version += 1
        announce("\(chord) removed")
    }

    func resetSelected() {
        guard let command = selected else { return }
        registry.resetKeys(of: command.id)
        version += 1
        announce("\(command.title): \(keysText(command.id))")
    }

    func resetAll() {
        registry.resetAllKeys()
        recorded = nil
        version += 1
        announce("All keys are back to their defaults")
    }

    private func announce(_ message: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

struct KeySettings: View {
    @State var model: KeysModel
    @State private var confirmingResetAll = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter commands", text: $model.filter)
                    .accessibilityLabel("Filter commands")
                    .textFieldStyle(.roundedBorder)
                List(selection: $model.selection) {
                    ForEach(model.commands, id: \.id) { command in
                        HStack {
                            Text(command.title)
                            Spacer()
                            Text(model.keysText(command.id))
                                .foregroundStyle(Theme.secondaryTextColor)
                        }
                        .tag(command.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(command.title), \(model.keysText(command.id))")
                    }
                }
                .accessibilityLabel("Commands")
                .accessibilityIdentifier("keys.commands")
                Button("Reset All Keys...") { confirmingResetAll = true }
                    .disabled(!model.hasAnyChanges)
            }
            .frame(minWidth: 380)

            VStack(alignment: .leading, spacing: 10) {
                if let command = model.selected {
                    Text("Keys for \(command.title)")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    let chords = model.chords(command.id)
                    if chords.isEmpty {
                        Text("No key")
                    }
                    ForEach(chords, id: \.self) { chord in
                        HStack {
                            Text(chord.description)
                                .accessibilityHidden(true)
                            Button("Remove") { model.remove(chord) }
                                .accessibilityLabel("Remove \(chord.description)")
                        }
                    }
                    KeyRecorder(title: "Record New Key", label: "Record new key for \(command.title)") { chord in
                        model.record(chord)
                    }
                    .frame(width: 220, height: 24)
                    Text("Press Record New Key, then the key to use. The next key pressed is recorded, also Tab, Return and Escape.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let chord = model.recorded {
                        Text(model.recordedDescription)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Assign \(chord.description)") { model.assignRecorded() }
                                .disabled(model.chords(command.id).contains(chord))
                            Button("Cancel") { model.recorded = nil }
                        }
                    }
                    Button("Reset \(command.title) to Default") { model.resetSelected() }
                        .disabled(!model.hasChangedKeys(command.id))
                } else {
                    Text("Choose a command to see and change its keys.")
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.selection) { model.recorded = nil }
        .alert("Reset all keys to their defaults?", isPresented: $confirmingResetAll) {
            Button("Reset All Keys", role: .destructive) { model.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every key you changed, added or removed goes back to Basil's default.")
        }
    }
}

/// A button that, once pressed (click, Space, Return or VO+Space), records the next key chord
/// pressed in it, including Tab, Return, Escape and Cmd chords.
struct KeyRecorder: NSViewRepresentable {
    let title: String
    let label: String
    let onRecord: (KeyChord) -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView()
        update(view)
        return view
    }

    func updateNSView(_ view: KeyRecorderView, context: Context) { update(view) }

    private func update(_ view: KeyRecorderView) {
        view.title = title
        view.label = label
        view.onRecord = onRecord
    }
}

final class KeyRecorderView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var label = ""
    var onRecord: ((KeyChord) -> Void)?
    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    func startRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Press the new key", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override func mouseDown(with event: NSEvent) { startRecording() }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            if let chord = KeyChord(event: event) { finish(chord) }
            return
        }
        if let chord = KeyChord(event: event), chord.modifiers.isEmpty, chord.key == .space || chord.key == .enter {
            startRecording()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self, event.type == .keyDown,
              let chord = KeyChord(event: event) else { return super.performKeyEquivalent(with: event) }
        finish(chord)
        return true
    }

    private func finish(_ chord: KeyChord) {
        isRecording = false
        onRecord?(chord)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = window?.firstResponder === self ? 2 : 1
        path.stroke()
        let text = isRecording ? "Press the new key" : title
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                         .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { isRecording ? "Press the new key" : nil }
    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }
    override func accessibilityIdentifier() -> String { "keys.recorder" }
}
