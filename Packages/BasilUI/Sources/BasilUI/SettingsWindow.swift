import AppKit
import BasilCore
import SwiftUI

public enum SettingsTab: String, Hashable, Sendable {
    case views, display, navigation, bookmarks
}

@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .views
}

/// The settings window (Cmd+,). One shared window; `show(tab:)` brings it forward on a tab.
@MainActor
public final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    private let navigation = SettingsNavigation()

    public static func show(settings: SettingsStore, tab: SettingsTab = .views) {
        let controller = shared ?? SettingsWindowController(settings: settings)
        shared = controller
        controller.navigation.tab = tab
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(settings: SettingsStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Basil Settings"
        window.setFrameAutosaveName("BasilSettingsWindow")
        // Wide enough that all tabs fit in the toolbar (otherwise one hides behind an overflow button).
        window.contentMinSize = NSSize(width: 720, height: 480)
        super.init(window: window)
        let hosting = NSHostingController(rootView: SettingsView(store: settings, navigation: navigation))
        hosting.view.setAccessibilityLabel("Settings")
        window.contentViewController = hosting
        if !window.setFrameUsingName("BasilSettingsWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct SettingsView: View {
    @Bindable var store: SettingsStore
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            ViewsSettings(store: store)
                .tabItem { Text("Views and Columns") }
                .tag(SettingsTab.views)
            DisplaySettings(store: store)
                .tabItem { Text("Display") }
                .tag(SettingsTab.display)
            NavigationSettings(store: store)
                .tabItem { Text("Navigation") }
                .tag(SettingsTab.navigation)
            BookmarkSettings(store: store)
                .tabItem { Text("Bookmarks") }
                .tag(SettingsTab.bookmarks)
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Views and columns

struct ViewsSettings: View {
    @Bindable var store: SettingsStore
    @State private var viewID = ListView.full.id
    @State private var selectedColumn: ColumnID?

    private var viewIndex: Int? { store.settings.views.firstIndex { $0.id == viewID } }
    private var currentView: ListView? { viewIndex.map { store.settings.views[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("View", selection: $viewID) {
                    ForEach(store.settings.views) { view in Text(view.name).tag(view.id) }
                }
                .frame(maxWidth: 280)
                Button("New View", action: newView)
                Button("Delete View", action: deleteView)
                    .disabled(currentView?.isBuiltin ?? true)
            }
            if let index = viewIndex, !store.settings.views[index].isBuiltin {
                TextField("View name", text: $store.settings.views[index].name)
                    .frame(maxWidth: 280)
            }

            Text("Columns")
                .font(.headline)
            Text("Checked columns are shown, in this order. The Name column is always shown.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let index = viewIndex {
                List(selection: $selectedColumn) {
                    ForEach(store.settings.views[index].columns, id: \.id) { spec in
                        columnRow(spec, viewIndex: index)
                    }
                }
                .accessibilityLabel("Columns")
                .frame(minHeight: 200)

                HStack {
                    Button("Move Up") { moveSelected(by: -1) }
                        .disabled(!canMove(by: -1))
                    Button("Move Down") { moveSelected(by: 1) }
                        .disabled(!canMove(by: 1))
                    Menu("Add Column") {
                        ForEach(availableColumns, id: \.id) { def in
                            Button(def.title) { addColumn(def.id) }
                        }
                    }
                    .disabled(availableColumns.isEmpty)
                    .fixedSize()
                    Button("Remove Column", action: removeSelected)
                        .disabled(selectedColumn == nil || selectedColumn == .name)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func columnRow(_ spec: ColumnSpec, viewIndex index: Int) -> some View {
        let title = ColumnCatalog.definition(spec.id)?.title ?? spec.id.rawValue
        Toggle(title, isOn: Binding(
            get: { spec.id == .name || spec.isVisible },
            set: { newValue in
                if let i = store.settings.views[index].columns.firstIndex(where: { $0.id == spec.id }) {
                    store.settings.views[index].columns[i].isVisible = newValue
                }
            }
        ))
        .disabled(spec.id == .name)
        .tag(spec.id)
        .accessibilityAction(named: "Move Up") { selectedColumn = spec.id; moveSelected(by: -1) }
        .accessibilityAction(named: "Move Down") { selectedColumn = spec.id; moveSelected(by: 1) }
    }

    private var availableColumns: [ColumnDefinition] {
        guard let view = currentView else { return [] }
        return ColumnCatalog.all.filter { def in !view.columns.contains { $0.id == def.id } }
    }

    private func canMove(by offset: Int) -> Bool {
        guard let view = currentView, let selected = selectedColumn,
              let i = view.columns.firstIndex(where: { $0.id == selected }) else { return false }
        return view.columns.indices.contains(i + offset)
    }

    private func moveSelected(by offset: Int) {
        guard let index = viewIndex, let selected = selectedColumn,
              let i = store.settings.views[index].columns.firstIndex(where: { $0.id == selected }),
              store.settings.views[index].columns.indices.contains(i + offset) else { return }
        store.settings.views[index].columns.swapAt(i, i + offset)
        let title = ColumnCatalog.definition(selected)?.title ?? selected.rawValue
        announce("\(title) moved to position \(i + offset + 1)")
    }

    private func addColumn(_ id: ColumnID) {
        guard let index = viewIndex else { return }
        store.settings.views[index].columns.append(ColumnSpec(id))
        selectedColumn = id
    }

    private func removeSelected() {
        guard let index = viewIndex, let selected = selectedColumn, selected != .name else { return }
        store.settings.views[index].columns.removeAll { $0.id == selected }
        selectedColumn = nil
    }

    private func newView() {
        let count = store.settings.views.filter { !$0.isBuiltin }.count
        let view = ListView(id: UUID().uuidString, name: "Custom \(count + 1)", columns: ListView.full.columns)
        store.settings.views.append(view)
        viewID = view.id
    }

    private func deleteView() {
        guard let view = currentView, !view.isBuiltin else { return }
        store.settings.views.removeAll { $0.id == view.id }
        viewID = ListView.full.id
    }
}

// MARK: - Display

struct DisplaySettings: View {
    @Bindable var store: SettingsStore
    @State private var customPattern = ""

    private static let customTag = "\u{0}custom"

    var body: some View {
        Form {
            Section("Size column") {
                Picker("Unit", selection: $store.settings.size.unit) {
                    ForEach(SizeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("1 KB equals", selection: $store.settings.size.base) {
                    Text("1024 bytes").tag(1024)
                    Text("1000 bytes").tag(1000)
                }
                Text("Examples: \(examples)")
                    .foregroundStyle(.secondary)
            }
            Section("Date column") {
                Picker("Date format", selection: datePresetBinding) {
                    ForEach(DateFormatSettings.presets, id: \.pattern) { Text($0.title).tag($0.pattern) }
                    Text("Custom").tag(Self.customTag)
                }
                if isCustomPattern {
                    TextField("Pattern, for example yyyy-MM-dd", text: Binding(
                        get: { store.settings.date.datePattern },
                        set: { store.settings.date.datePattern = $0 }
                    ))
                    Text("Letters: yyyy year, MM month, dd day, MMM month name, EEE weekday.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Time", selection: $store.settings.date.time) {
                    ForEach(TimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Example: \(store.formatters.date(Date()))")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var examples: String {
        let f = store.settings.size
        return [512, 1_536, 5_242_880, 3_221_225_472].map { f.string(Int64($0)) }.joined(separator: ", ")
    }

    private var isCustomPattern: Bool {
        !DateFormatSettings.presets.contains { $0.pattern == store.settings.date.datePattern }
            || customPattern == Self.customTag
    }

    private var datePresetBinding: Binding<String> {
        Binding(
            get: { isCustomPattern ? Self.customTag : store.settings.date.datePattern },
            set: { newValue in
                if newValue == Self.customTag {
                    customPattern = Self.customTag
                } else {
                    customPattern = ""
                    store.settings.date.datePattern = newValue
                }
            }
        )
    }
}

// MARK: - Navigation

struct NavigationSettings: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle("Go to the root when switching to a volume", isOn: $store.settings.goToRootOnVolumeSwitch)
            Text("When off, switching to a volume from the drive menu returns to the last folder you visited on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Bookmarks

struct BookmarkSettings: View {
    @Bindable var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmarks appear in the locations menu (Cmd+D, Cmd+F1, Cmd+F2). Add one from that menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($store.settings.bookmarks) { $bookmark in
                    HStack {
                        TextField("Name", text: $bookmark.name)
                            .frame(maxWidth: 200)
                        Text(bookmark.path.description)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .tag(bookmark.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Move Up") { selection = bookmark.id; move(by: -1) }
                    .accessibilityAction(named: "Move Down") { selection = bookmark.id; move(by: 1) }
                    .accessibilityAction(named: "Remove") { selection = bookmark.id; remove() }
                }
            }
            .accessibilityLabel("Bookmarks")
            HStack {
                Button("Move Up") { move(by: -1) }.disabled(selection == nil)
                Button("Move Down") { move(by: 1) }.disabled(selection == nil)
                Button("Remove", action: remove).disabled(selection == nil)
            }
        }
    }

    private func move(by offset: Int) {
        guard let id = selection, let i = store.settings.bookmarks.firstIndex(where: { $0.id == id }),
              store.settings.bookmarks.indices.contains(i + offset) else { return }
        store.settings.bookmarks.swapAt(i, i + offset)
    }

    private func remove() {
        guard let id = selection else { return }
        store.settings.bookmarks.removeAll { $0.id == id }
        selection = nil
        announce("Bookmark removed")
    }
}

@MainActor
private func announce(_ message: String) {
    guard let window = NSApp.keyWindow else { return }
    NSAccessibility.post(element: window, notification: .announcementRequested,
                         userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}
