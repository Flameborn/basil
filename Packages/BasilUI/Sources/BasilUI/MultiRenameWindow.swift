import AppKit
import BasilCore
import BasilOperations
import SwiftUI

/// The Multi-Rename tool (Cmd+M), like Total Commander's: its own window, modal to the app.
/// It only builds the list of renames; the batch runs as one queue operation.
@MainActor
@Observable
final class MultiRenameModel {
    let items: [FileItem]
    private let existingNames: [String]
    let undoLog: URL

    var rule = RenameRule() { didSet { if rule != oldValue { refreshPreview() } } }
    private(set) var entries: [RenamePreviewEntry] = []
    private(set) var undoAvailable = false
    var presetName = ""

    @ObservationIgnored private var generation = 0
    @ObservationIgnored var onStart: (([RenamePreviewEntry]) -> Void)?
    @ObservationIgnored var onUndo: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    init(items: [FileItem], existingNames: [String], undoLog: URL) {
        self.items = items
        self.existingNames = existingNames
        self.undoLog = undoLog
        undoAvailable = !(MultiRenameOperation.readLog(undoLog) ?? []).isEmpty
        entries = MultiRenamePreview.make(items: items, rule: rule, existingNames: existingNames)
    }

    var searchError: String? { MultiRename.searchError(rule) }
    var changed: Int { entries.filter { !$0.isUnchanged }.count }
    var problems: Int { entries.filter { $0.problem != nil }.count }
    var canStart: Bool { searchError == nil && problems == 0 && changed > 0 }

    var status: String {
        if let searchError { return searchError }
        var parts = [FeedbackText.items(entries.count), "\(changed) changed"]
        if problems > 0 { parts.append(problems == 1 ? "1 problem" : "\(problems) problems") }
        return parts.joined(separator: ", ")
    }

    /// Recomputes the new names off the main actor; results from an older rule are dropped.
    private func refreshPreview() {
        generation += 1
        let token = generation
        let (items, rule, existing) = (self.items, self.rule, self.existingNames)
        Task {
            let result = await Task.detached {
                MultiRenamePreview.make(items: items, rule: rule, existingNames: existing)
            }.value
            guard token == self.generation else { return }
            self.entries = result
        }
    }

    func appendToNameMask(_ text: String) { rule.nameMask += text }
    func appendToExtensionMask(_ text: String) { rule.extensionMask += text }
}

struct MultiRenameView: View {
    @Bindable var model: MultiRenameModel
    @Bindable var settings: SettingsStore
    @FocusState private var nameMaskFocused: Bool

    /// Placeholders offered in the Insert menus: title and the text inserted.
    private var placeholders: [(String, String)] {
        [("Name", "[N]"), ("Extension", "[E]"), ("Counter", "[C]"), ("Parent folder", "[P]"),
         ("Grandparent folder", "[G]"), ("Year", "[Y]"), ("Month", "[M]"), ("Day", "[D]"),
         ("Hour", "[h]"), ("Minute", "[m]"), ("Second", "[s]")]
            + MultiRenamePlaceholders.all.map { ($0.title, "[=\($0.name)]") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                masks
                VStack(alignment: .leading, spacing: 12) {
                    searchAndCase
                    counter
                }
            }
            presets
            preview
            HStack {
                Text(model.status)
                    .foregroundStyle(model.problems > 0 || model.searchError != nil ? Color.red : Color.secondary)
                    .accessibilityLabel("Status, \(model.status)")
                Spacer()
                Button("Undo Last Rename") { model.onUndo?() }
                    .disabled(!model.undoAvailable)
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { model.onStart?(model.entries) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { nameMaskFocused = true }
    }

    private var masks: some View {
        Form {
            HStack {
                TextField("Name mask", text: $model.rule.nameMask)
                    .focused($nameMaskFocused)
                    .accessibilityLabel("Name mask")
                Menu("Insert") {
                    ForEach(placeholders, id: \.1) { title, text in
                        Button("\(title) \(text)") { model.appendToNameMask(text) }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Insert in name mask")
            }
            HStack {
                TextField("Extension mask", text: $model.rule.extensionMask)
                    .accessibilityLabel("Extension mask")
                Menu("Insert") {
                    ForEach(placeholders, id: \.1) { title, text in
                        Button("\(title) \(text)") { model.appendToExtensionMask(text) }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Insert in extension mask")
            }
            Picker("Case", selection: $model.rule.nameCase) {
                ForEach(RenameCase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        .frame(minWidth: 380)
    }

    private var searchAndCase: some View {
        Form {
            TextField("Search for", text: $model.rule.search)
                .accessibilityLabel("Search for")
            TextField("Replace with", text: $model.rule.replace)
                .accessibilityLabel("Replace with")
            HStack {
                Toggle("Regular expression", isOn: $model.rule.regex)
                    .accessibilityLabel("Regular expression")
                Toggle("Case sensitive", isOn: $model.rule.caseSensitive)
                    .accessibilityLabel("Case sensitive")
            }
        }
    }

    private var counter: some View {
        Form {
            HStack {
                TextField("Counter start", value: $model.rule.counterStart, format: .number)
                    .accessibilityLabel("Counter start")
                Stepper("Step \(model.rule.counterStep)", value: $model.rule.counterStep, in: -1000...1000)
                    .accessibilityLabel("Counter step")
                Stepper("Digits \(model.rule.counterDigits)", value: $model.rule.counterDigits, in: 1...10)
                    .accessibilityLabel("Counter digits")
            }
        }
    }

    private var presets: some View {
        HStack {
            Menu("Load Preset") {
                ForEach(settings.settings.renamePresets) { preset in
                    Button(preset.name) {
                        model.rule = preset.rule
                        model.presetName = preset.name
                    }
                }
            }
            .fixedSize()
            .disabled(settings.settings.renamePresets.isEmpty)
            TextField("Preset name", text: $model.presetName)
                .frame(maxWidth: 240)
                .accessibilityLabel("Preset name")
            Button("Save Preset") { savePreset() }
                .disabled(model.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Menu("Delete Preset") {
                ForEach(settings.settings.renamePresets) { preset in
                    Button(preset.name) { settings.settings.renamePresets.removeAll { $0.id == preset.id } }
                }
            }
            .fixedSize()
            .disabled(settings.settings.renamePresets.isEmpty)
            Spacer()
        }
    }

    /// Saving under an existing name replaces that preset.
    private func savePreset() {
        let name = model.presetName.trimmingCharacters(in: .whitespaces)
        if let index = settings.settings.renamePresets.firstIndex(where: { $0.name == name }) {
            settings.settings.renamePresets[index].rule = model.rule
        } else {
            settings.settings.renamePresets.append(RenamePreset(name: name, rule: model.rule))
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Old name").frame(width: 300, alignment: .leading)
                Text("New name").frame(width: 300, alignment: .leading)
                Text("Problem")
            }
            .font(.headline)
            .accessibilityHidden(true)
            List(model.entries) { entry in
                HStack {
                    Text(entry.item.name).frame(width: 300, alignment: .leading)
                    Text(entry.newName).frame(width: 300, alignment: .leading)
                    if let problem = entry.problem {
                        Text(problem.text).foregroundStyle(.red)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(spoken(entry))
            }
            .accessibilityLabel("Preview")
        }
    }

    /// "song.mp3, to 01 song.mp3" or "song.mp3, unchanged", plus the problem.
    private func spoken(_ entry: RenamePreviewEntry) -> String {
        var text = entry.isUnchanged ? "\(entry.item.name), unchanged" : "\(entry.item.name), to \(entry.newName)"
        if let problem = entry.problem { text += ", problem: \(problem.text)" }
        return text
    }
}

/// Shows the tool modally and calls back with the chosen renames.
@MainActor
final class MultiRenameWindowController: NSWindowController, NSWindowDelegate {
    private let model: MultiRenameModel

    init(model: MultiRenameModel, settings: SettingsStore) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Multi-Rename"
        window.setFrameAutosaveName("BasilMultiRenameWindow")
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: MultiRenameView(model: model, settings: settings))
        hosting.view.setAccessibilityLabel("Multi-Rename")
        window.contentViewController = hosting
        if !window.setFrameUsingName("BasilMultiRenameWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Runs the window modally; returns when it is closed.
    func runModal() {
        guard let window else { return }
        let close: () -> Void = { [weak self] in self?.window?.close() }
        model.onClose = close
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
