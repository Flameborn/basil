import AppKit
import BasilCore
import SwiftUI
import UniformTypeIdentifiers

extension SettingsStore {
    /// The theme Settings chose (Basil's own when the chosen one is gone).
    var activeTheme: ThemeDefinition {
        let id = settings.themeID
        return settings.customThemes.first { $0.id == id } ?? .builtin
    }
}

extension MainWindowController {
    /// Applies the chosen theme now and whenever Settings changes it.
    func followTheme() {
        Theme.apply(settings.activeTheme)
        themeToken = settings.onChange { [weak self] _ in
            guard let self else { return }
            Theme.apply(self.settings.activeTheme)
        }
    }
}

/// Settings > Themes: Basil's own theme (read only) and the user's, each colour for light and
/// dark mode with its hex value, a contrast list, and import and export as .basiltheme files.
/// A change that would make text or an outline too faint against what it is drawn on (WCAG:
/// 4.5 to 1 for text, 3 to 1 for outlines) is refused and the reason said.
struct ThemeSettings: View {
    @Bindable var store: SettingsStore
    @State private var message = ""

    private var themes: [ThemeDefinition] { [.builtin] + store.settings.customThemes }
    private var current: ThemeDefinition { store.activeTheme }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $store.settings.themeID) {
                    ForEach(themes) { theme in Text(theme.name).tag(theme.id) }
                }
                .accessibilityLabel("Theme")
                HStack {
                    Button("Duplicate Theme") { duplicate() }
                    Button("Delete Theme") { delete() }
                        .disabled(current.isBuiltin)
                    Button("Import Theme...") { importTheme() }
                    Button("Export Theme...") { exportTheme() }
                }
                if current.isBuiltin {
                    Text("Basil's own theme cannot be changed. Duplicate it to make one of your own.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                } else {
                    TextField("Name", text: Binding(get: { current.name }, set: { rename($0) }))
                        .accessibilityLabel("Theme name")
                }
                if !message.isEmpty {
                    Text(message)
                        .accessibilityLabel(message)
                        .accessibilityIdentifier("themes.message")
                }
            }
            Section("Colours") {
                ForEach(ThemeToken.allCases, id: \.self) { token in
                    ThemeColorRow(token: token, color: current.color(token), editable: !current.isBuiltin) { light, dark in
                        change(token, light: light, dark: dark)
                    }
                }
            }
            Section("Contrast") {
                ForEach(Array(ThemeContrast.report(current).enumerated()), id: \.offset) { _, entry in
                    let text = Self.line(entry.pair, entry.light, entry.dark)
                    Text(text)
                        .accessibilityLabel(text)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func line(_ pair: ThemeContrast.Pair, _ light: Double, _ dark: Double) -> String {
        func ratio(_ r: Double) -> String { String(format: "%.1f", r) + " to 1" + (r < pair.minimum ? " (too low)" : "") }
        return "\(pair.title): \(ratio(light)) light, \(ratio(dark)) dark"
    }

    private func say(_ text: String) {
        message = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func update(_ theme: ThemeDefinition) {
        if let index = store.settings.customThemes.firstIndex(where: { $0.id == theme.id }) {
            store.settings.customThemes[index] = theme
        }
    }

    /// A new value, refused when a pair with this colour would fall below its contrast.
    private func change(_ token: ThemeToken, light: UInt32, dark: UInt32) {
        var theme = current
        guard !theme.isBuiltin else { return }
        theme.colors[token] = ThemeColor(light: light, dark: dark)
        let problems = ThemeContrast.problems(theme).filter { $0.pair.foreground == token || $0.pair.background == token }
        if let problem = problems.first {
            say("Not changed: \(problem).")
            return
        }
        update(theme)
        message = ""
    }

    private func rename(_ name: String) {
        var theme = current
        guard !theme.isBuiltin, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        theme.name = name
        update(theme)
    }

    private func duplicate() {
        var copy = current
        copy.id = UUID().uuidString
        copy.name = current.name + " copy"
        copy.colors = Dictionary(uniqueKeysWithValues: ThemeToken.allCases.map { ($0, current.color($0)) })
        store.settings.customThemes.append(copy)
        store.settings.themeID = copy.id
        say("Made \(copy.name)")
    }

    private func delete() {
        let theme = current
        guard !theme.isBuiltin else { return }
        store.settings.customThemes.removeAll { $0.id == theme.id }
        store.settings.themeID = ThemeDefinition.builtinID
        say("Deleted \(theme.name). Using Basil's own theme")
    }

    private static let fileType = UTType(filenameExtension: "basiltheme") ?? .json

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.message = "Choose a Basil theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
            let problems = ThemeContrast.problems(theme)
            guard problems.isEmpty else {
                let list = problems.prefix(3).map(\.description).joined(separator: "; ")
                return say("\(theme.name) was not imported: \(list)\(problems.count > 3 ? "; and \(problems.count - 3) more" : "").")
            }
            if theme.isBuiltin || store.settings.customThemes.contains(where: { $0.id == theme.id }) { theme.id = UUID().uuidString }
            store.settings.customThemes.append(theme)
            store.settings.themeID = theme.id
            say("Imported \(theme.name)")
        } catch {
            say("\(url.lastPathComponent) is not a Basil theme: \(error.localizedDescription)")
        }
    }

    private func exportTheme() {
        let theme = current
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = theme.name + ".basiltheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(theme).write(to: url, options: .atomic)
            say("Exported \(theme.name)")
        } catch {
            say("\(theme.name) could not be saved: \(error.localizedDescription)")
        }
    }
}

/// One colour: its name, and for light and dark mode a hex field and a colour picker (only
/// shown, not editable, for Basil's own theme).
struct ThemeColorRow: View {
    let token: ThemeToken
    let color: ThemeColor
    let editable: Bool
    let change: (UInt32, UInt32) -> Void

    var body: some View {
        HStack {
            Text(token.title)
                .frame(minWidth: 240, alignment: .leading)
            side("Light", color.light) { change($0, color.dark) }
            side("Dark", color.dark) { change(color.light, $0) }
        }
    }

    @ViewBuilder
    private func side(_ mode: String, _ value: UInt32, _ set: @escaping (UInt32) -> Void) -> some View {
        let label = "\(token.title), \(mode.lowercased())"
        HexField(label: label, value: value, editable: editable, set: set)
        if editable {
            ColorPicker(label + ", colour", selection: Binding(get: { Color(nsColor: NSColor(hex: value)) }, set: { picked in
                if let rgb = NSColor(picked).usingColorSpace(.sRGB) {
                    func byte(_ c: CGFloat) -> UInt32 { UInt32(max(0, min(255, (c * 255).rounded()))) }
                    set(byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent))
                }
            }), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

/// "#1A2B3C", typed and taken on Return.
struct HexField: View {
    let label: String
    let value: UInt32
    let editable: Bool
    let set: (UInt32) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .frame(width: 90)
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(label)
            .disabled(!editable)
            .onAppear { text = ThemeColor.hex(value) }
            .onChange(of: value) { text = ThemeColor.hex(value) }
            .onSubmit {
                if let parsed = ThemeColor.parse(text) { set(parsed) }
                text = ThemeColor.hex(value)
            }
    }
}
