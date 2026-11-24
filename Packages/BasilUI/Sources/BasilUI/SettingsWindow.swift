import AppKit
import BasilCore
import BasilIntegrations
import BasilPlugins
import SwiftUI

/// The sections of Settings, in the sidebar's order.
public enum SettingsTab: String, Hashable, Sendable, CaseIterable {
    case general, views, display, navigation, search, bookmarks, copying, editing, sounds, keys, plugins, themes

    var title: String {
        switch self {
        case .general: "General"
        case .views: "Views and Columns"
        case .display: "Display"
        case .navigation: "Navigation"
        case .search: "Search"
        case .bookmarks: "Bookmarks"
        case .copying: "Copying"
        case .editing: "Editor and Terminal"
        case .sounds: "Sounds and Speech"
        case .keys: "Keys"
        case .plugins: "Plugins"
        case .themes: "Themes"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// The settings window (Cmd+,). One shared window; `show(tab:)` brings it forward on a tab.
@MainActor
public final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    private let navigation = SettingsNavigation()
    /// The commands whose keys the Keys tab changes (set by the main window).
    static var commands: CommandRegistry?
    /// Check Now in General (set by the main window).
    static var checkForUpdates: (() -> Void)?
    /// The search index's status and Rebuild in Search (set by the main window).
    static var searchIndex: SearchIndexStatus?
    /// The plugins for the Plugins tab (set by the main window).
    static var plugins: PluginManager?

    public static func show(settings: SettingsStore, tab: SettingsTab = .general) {
        let controller = shared ?? SettingsWindowController(settings: settings)
        shared = controller
        controller.navigation.tab = tab
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(settings: SettingsStore) {
        let window = SettingsNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Basil Settings"
        window.basilAutosave("BasilSettingsWindow")
        window.contentMinSize = NSSize(width: 1000, height: 520)
        super.init(window: window)
        let keys = Self.commands.map { KeysModel(registry: $0) }
        // The sidebar and the chosen section side by side, as two hosting controllers in an
        // AppKit split view (so the sidebar's container has a name for VoiceOver).
        let sidebar = NSHostingController(rootView: SettingsSidebar(navigation: navigation, keys: keys))
        sidebar.view.setAccessibilityLabel("Settings sections")
        let detail = NSHostingController(rootView: SettingsView(store: settings, navigation: navigation, keys: keys))
        detail.view.setAccessibilityLabel("Settings")
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .init(260)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        split.view.setAccessibilityLabel("Settings")
        window.contentViewController = split
        if !window.setFrameUsingName("BasilSettingsWindow") { window.center() }
        // A frame saved before a tab was added can be too narrow for all tabs.
        let content = window.contentRect(forFrameRect: window.frame)
        if content.width < window.contentMinSize.width {
            window.setContentSize(NSSize(width: window.contentMinSize.width, height: max(content.height, window.contentMinSize.height)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Cmd+W closes the settings window. The main menu has no Close item, because Cmd+W must not
/// close the main window (that would quit the app).
final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While a key is being recorded, every key goes to the recorder (Cmd+W too).
        if let recorder = firstResponder as? KeyRecorderView, recorder.isRecording {
            return recorder.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The sections of Settings; Up and Down move between them, Tab goes into the section. Drawn
/// by Basil (not a List): the system draws a selected row white on the accent colour, under
/// 4.5 to 1; here it is white on the cursor colour (5.8 to 1 and more).
struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation
    let keys: KeysModel?
    @FocusState private var focused: Bool

    var body: some View {
        let sections = SettingsView.sections(keys: keys)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.self) { tab in
                    let selected = tab == navigation.tab
                    Text(tab.title)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color(nsColor: Theme.cursorBackground) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigation.tab = tab
                            focused = true
                        }
                        .accessibilityElement()
                        .accessibilityLabel(tab.title)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { navigation.tab = tab }
                }
            }
            .padding(10)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled(false)
        .onKeyPress(.upArrow) { move(-1, in: sections) }
        .onKeyPress(.downArrow) { move(1, in: sections) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        .accessibilityIdentifier("settings.sections")
        .frame(minWidth: 180)
        .onAppear { focused = true }
    }

    private func move(_ step: Int, in sections: [SettingsTab]) -> KeyPress.Result {
        guard let index = sections.firstIndex(of: navigation.tab) else { return .ignored }
        let next = min(max(index + step, 0), sections.count - 1)
        navigation.tab = sections[next]
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: sections[next].title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return .handled
    }
}

/// The chosen section of Settings.
struct SettingsView: View {
    @Bindable var store: SettingsStore
    @Bindable var navigation: SettingsNavigation
    let keys: KeysModel?

    static func sections(keys: KeysModel?) -> [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            switch tab {
            case .keys: keys != nil
            case .plugins: SettingsWindowController.plugins != nil
            case .search: SettingsWindowController.searchIndex != nil
            default: true
            }
        }
    }

    var body: some View {
        section(navigation.tab)
            .padding()
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(store: store)
        case .views: ViewsSettings(store: store)
        case .display: DisplaySettings(store: store)
        case .navigation: NavigationSettings(store: store)
        case .search:
            if let index = SettingsWindowController.searchIndex {
                Form { SearchIndexSettings(store: store, index: index) }.formStyle(.grouped)
            }
        case .bookmarks: BookmarkSettings(store: store)
        case .copying: CopySettings(store: store)
        case .editing: EditorSettings(store: store)
        case .sounds: FeedbackSettingsView(store: store)
        case .keys: if let keys { KeySettings(model: keys) }
        case .plugins: if let plugins = SettingsWindowController.plugins { PluginSettings(manager: plugins) }
        case .themes: ThemeSettings(store: store)
        }
    }
}

/// General: updates.
struct GeneralSettings: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $store.settings.checkForUpdates)
                .accessibilityLabel("Check for updates automatically")
            Text("Basil looks for a new release on GitHub when it starts and once a day, and asks before installing it. Basil > Check for Updates... looks at any time.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            if let check = SettingsWindowController.checkForUpdates {
                Button("Check for Updates Now") { check() }
            }
        }
        .formStyle(.grouped)
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
                // A Picker's own label outside a Form fails the dark-mode contrast audit; the separate
                // text is hidden from VoiceOver, which reads the picker's label instead.
                Text("View").accessibilityHidden(true)
                Picker("View", selection: $viewID) {
                    ForEach(store.settings.views) { view in Text(view.name).tag(view.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
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
                .foregroundStyle(Theme.secondaryTextColor)

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
                    .foregroundStyle(Theme.secondaryTextColor)
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
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Picker("Time", selection: $store.settings.date.time) {
                    ForEach(TimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Example: \(store.formatters.date(Date()))")
                    .foregroundStyle(Theme.secondaryTextColor)
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
            Toggle("Go to the root when choosing a volume", isOn: $store.settings.goToRootOnVolumeSwitch)
                .accessibilityLabel("Go to the root when choosing a volume")
            Text("When off, choosing a volume from the drive menu returns to the last folder you visited on it.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Toggle("Space calculates folder sizes", isOn: $store.settings.spaceCalculatesFolderSizes)
                .accessibilityLabel("Space calculates folder sizes")
            Text("When on, selecting a folder with Space also calculates its size, like Cmd+Shift+S.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
        }
        .formStyle(.grouped)
    }
}

/// Basil's own filename indexes (Find Files): which volumes, what each is doing, Rebuild, and how
/// often network volumes are scanned again.
struct SearchIndexSettings: View {
    @Bindable var store: SettingsStore
    let index: SearchIndexStatus

    var body: some View {
        Text("Search index")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        Text("Find Files finds names at once on the volumes ticked here. Each index is built in the background and kept up to date while Basil runs; changes made while Basil was closed or the disk was not connected are read when it is back. Network volumes also see changes made from other computers only when they are scanned again.")
            .font(.callout)
            .foregroundStyle(Theme.secondaryTextColor)
        ForEach(index.rows) { row in
            let title = Self.title(row)
            Toggle(title, isOn: Binding(get: { index.isOn(row) }, set: { index.set(row, on: $0) }))
                .accessibilityLabel(title)
            HStack {
                Text(row.status)
                    .accessibilityLabel(row.status)
                    .accessibilityIdentifier("settings.indexStatus." + (row.id == "boot" ? "boot" : row.name))
                Spacer()
                Button("Rebuild Index") { index.rebuild(row) }
                    .accessibilityLabel("Rebuild Index of \(row.name)")
                    .disabled(!index.isOn(row) || !row.isMounted)
            }
        }
        Stepper(value: $store.settings.networkIndexRescanHours, in: 1...168) {
            Text("Scan network volumes again every \(store.settings.networkIndexRescanHours) hours")
        }
        .accessibilityLabel("Scan network volumes again every \(store.settings.networkIndexRescanHours) hours")
    }

    static func title(_ row: SearchIndexStatus.Row) -> String {
        if row.id == "boot" { return "\(row.name), startup disk" }
        var title = row.name
        if row.isNetwork { title += ", network volume" }
        if !row.isMounted { title += ", not mounted" }
        return title
    }
}

// MARK: - Copying

struct CopySettings: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle("Show a progress window for operations", isOn: $store.settings.showProgressWindow)
                .accessibilityLabel("Show a progress window for operations")
            Text("Like Total Commander: a running copy, move, delete, pack or test shows its progress in a window with Background, Pause and Cancel. Background hides it; the operation keeps running in the queue (Cmd+J).")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Toggle("Secure copy and move", isOn: $store.settings.secureCopy)
                .accessibilityLabel("Secure copy and move")
            Text("On: Basil copies into a temporary file, checks afterwards whether the source changed during the copy and copies the changed parts again, flushes to disk, then renames the file into place. A move deletes the source only when its copy is complete. Off (default): copying works like Total Commander and writes straight to the target. A file that is still being written can then be copied incomplete.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Toggle("Verify copies by reading the destination back", isOn: $store.settings.verifyCopies)
                .accessibilityLabel("Verify copies by reading the destination back")
            Text("Reads every copied file again and compares it with what was read from the source. Slower; off by default. Applies to copy and move.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Stepper(value: $store.settings.unstableSourceRetries, in: 0...10) {
                Text("Retries when a file changes during copying: \(store.settings.unstableSourceRetries)")
            }
            .accessibilityLabel("Retries when a file changes during copying")
            .accessibilityValue("\(store.settings.unstableSourceRetries)")
            Text("Secure mode only. A file that is still being written is read again this many times, waiting longer each time, before Basil asks what to do.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Toggle("Store macOS metadata in archives", isOn: $store.settings.packMacMetadata)
                .accessibilityLabel("Store macOS metadata in archives")
            Text("Packing zip and tar archives keeps extended attributes, Finder tags and resource forks, the way Finder does (zip archives get a __MACOSX folder, which other systems show as extra files). Basil restores them when extracting. On by default.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor and terminal

struct EditorSettings: View {
    @Bindable var store: SettingsStore
    @State private var ruleID: UUID?
    @State private var appIndex: Int?

    private var editorName: String {
        store.settings.editorAppPath.map(EditorLauncher.displayName(ofApp:)) ?? "System default"
    }

    private var ruleIndex: Int? { ruleID.flatMap { id in store.settings.editorRules.firstIndex { $0.id == id } } }

    var body: some View {
        // The rule lists stay outside the grouped Form: a List inside a Form fails the accessibility audit.
        HStack(alignment: .top, spacing: 16) {
            Form {
                Section("Editor") {
                    Text("Editor: \(editorName)")
                    HStack {
                        Button("Choose Editor...") { if let path = chooseApp(title: "Choose Editor") { store.settings.editorAppPath = path } }
                        Button("Use System Default") { store.settings.editorAppPath = nil }
                            .disabled(store.settings.editorAppPath == nil)
                    }
                    Text("F4 edits the file under the cursor and Shift+F4 creates a file and opens it. Files that match a rule open with that rule's apps, all others in this editor. System default opens each file in the app macOS uses for its type, and files no app opens in TextEdit.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Section("Terminal") {
                    Picker("Terminal", selection: $store.settings.terminalID) {
                        ForEach(terminals, id: \.id) { terminal in Text(terminal.name).tag(terminal.id) }
                    }
                    if store.settings.terminalID == TerminalCatalog.custom.id {
                        TextField("Command", text: $store.settings.terminalCommand, prompt: Text("open -a Terminal {dir}"))
                            .accessibilityLabel("Command")
                    }
                    Text("Cmd+Shift+T opens the terminal in the current pane's folder. A custom command runs in the shell; {dir} is replaced by the folder path.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480)

            VStack(alignment: .leading, spacing: 8) {
                Text("Editors by file pattern")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                rulesList
                HStack {
                    Button("Add Rule", action: addRule)
                    Button("Move Up") { moveRule(by: -1) }.disabled(ruleIndex == nil)
                    Button("Move Down") { moveRule(by: 1) }.disabled(ruleIndex == nil)
                    Button("Remove Rule", action: removeRule).disabled(ruleIndex == nil)
                }
                if let i = ruleIndex { ruleEditor(i) }
                Text("Patterns work like the quick filter: *.txt;*.md matches either, and names after | are left out. The first matching rule wins. A rule with one app opens it directly; with several apps F4 shows a menu.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        }
    }

    /// Installed terminals, plus the chosen one even when it is not installed (so the picker shows it).
    private var terminals: [TerminalApp] {
        var list = TerminalCatalog.available
        if !list.contains(where: { $0.id == store.settings.terminalID }),
           let chosen = TerminalCatalog.terminal(id: store.settings.terminalID) {
            list.insert(chosen, at: 0)
        }
        return list
    }

    private func describe(_ rule: EditorRule) -> String {
        let patterns = rule.patterns.trimmingCharacters(in: .whitespaces).isEmpty ? "No patterns" : rule.patterns
        let apps = rule.apps.isEmpty ? "no apps" : rule.apps.map(EditorLauncher.displayName(ofApp:)).joined(separator: ", ")
        return "\(patterns): \(apps)"
    }

    private var rulesList: some View {
        List(selection: $ruleID) {
            ForEach(store.settings.editorRules) { rule in
                Text(describe(rule))
                    .lineLimit(1)
                    .tag(rule.id)
                    .accessibilityAction(named: "Move Up") { ruleID = rule.id; moveRule(by: -1) }
                    .accessibilityAction(named: "Move Down") { ruleID = rule.id; moveRule(by: 1) }
                    .accessibilityAction(named: "Remove") { ruleID = rule.id; removeRule() }
            }
        }
        .frame(minHeight: 90)
        .accessibilityLabel("Editor rules")
        .onChange(of: ruleID) { appIndex = nil }
    }

    @ViewBuilder
    private func ruleEditor(_ i: Int) -> some View {
        TextField("Patterns", text: $store.settings.editorRules[i].patterns, prompt: Text("*.txt;*.md"))
            .accessibilityLabel("Patterns")
        let apps = store.settings.editorRules[i].apps
        List(selection: $appIndex) {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                Text(EditorLauncher.displayName(ofApp: app))
                    .tag(index)
                    .accessibilityAction(named: "Move Up") { appIndex = index; moveApp(by: -1) }
                    .accessibilityAction(named: "Move Down") { appIndex = index; moveApp(by: 1) }
                    .accessibilityAction(named: "Remove") { appIndex = index; removeApp() }
            }
        }
        .frame(minHeight: 70)
        .accessibilityLabel("Apps for this rule")
        HStack {
            Button("Add App...") {
                guard let path = chooseApp(title: "Choose an App for \(store.settings.editorRules[i].patterns)") else { return }
                store.settings.editorRules[i].apps.append(path)
            }
            Button("Move App Up") { moveApp(by: -1) }.disabled(appIndex == nil)
            Button("Move App Down") { moveApp(by: 1) }.disabled(appIndex == nil)
            Button("Remove App", action: removeApp).disabled(appIndex == nil)
        }
    }

    private func addRule() {
        let rule = EditorRule(patterns: "")
        store.settings.editorRules.append(rule)
        ruleID = rule.id
    }

    private func moveRule(by offset: Int) {
        guard let i = ruleIndex, store.settings.editorRules.indices.contains(i + offset) else { return }
        store.settings.editorRules.swapAt(i, i + offset)
    }

    private func removeRule() {
        guard let i = ruleIndex else { return }
        store.settings.editorRules.remove(at: i)
        ruleID = nil
        announce("Rule removed")
    }

    private func moveApp(by offset: Int) {
        guard let r = ruleIndex, let a = appIndex,
              store.settings.editorRules[r].apps.indices.contains(a + offset) else { return }
        store.settings.editorRules[r].apps.swapAt(a, a + offset)
        appIndex = a + offset
    }

    private func removeApp() {
        guard let r = ruleIndex, let a = appIndex, store.settings.editorRules[r].apps.indices.contains(a) else { return }
        store.settings.editorRules[r].apps.remove(at: a)
        appIndex = nil
        announce("App removed")
    }

    private func chooseApp(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
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
                .foregroundStyle(Theme.secondaryTextColor)
            List(selection: $selection) {
                ForEach($store.settings.bookmarks) { $bookmark in
                    HStack {
                        TextField("Name", text: $bookmark.name)
                            .frame(maxWidth: 200)
                        Text(bookmark.path.description)
                            .foregroundStyle(Theme.secondaryTextColor)
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

// MARK: - Sounds and speech

/// Sound and speech per queue event. "Any operation" sets the defaults; each operation can
/// override any of its events.
struct FeedbackSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var kind: OperationKind? = nil
    @State private var player = EventFeedbackPlayer()
    private let soundNames = EventFeedbackPlayer.systemSoundNames()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // See ViewsSettings: the separate text avoids the Picker label's audit failure.
                Text("Operation").accessibilityHidden(true)
                Picker("Operation", selection: $kind) {
                    Text("Any operation").tag(OperationKind?.none)
                    ForEach(OperationKindCatalog.all, id: \.kind) { info in
                        Text(info.name).tag(OperationKind?.some(info.kind))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Text("Placeholders for the spoken text: \(FeedbackText.placeholderHelp). Speech goes to VoiceOver when it is running, otherwise the system voice speaks.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
            Form {
                ForEach(QueueOutcome.allCases, id: \.self) { outcome in
                    Section(outcome.title) { editor(outcome) }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func editor(_ outcome: QueueOutcome) -> some View {
        let label = outcome.title
        if let kind {
            let overridden = store.settings.feedback.override(for: kind, outcome) != nil
            Toggle("\(label): use the Any operation setting", isOn: Binding(
                get: { !overridden },
                set: { useDefault in
                    let current = store.settings.feedback.feedback(for: kind, outcome)
                    store.settings.feedback.setOverride(useDefault ? nil : current, for: kind, outcome)
                }
            ))
            .accessibilityLabel("\(label): use the Any operation setting")
            if overridden { fields(outcome, label: label) }
        } else {
            fields(outcome, label: label)
        }
    }

    @ViewBuilder
    private func fields(_ outcome: QueueOutcome, label: String) -> some View {
        let feedback = binding(outcome)
        HStack {
            Picker("\(label) sound", selection: soundBinding(feedback)) {
                Text("None").tag("none")
                ForEach(soundNames, id: \.self) { Text($0).tag("system:" + $0) }
                if case .file(let path) = feedback.wrappedValue.sound {
                    Text((path as NSString).lastPathComponent).tag("file:" + path)
                }
                Text("Choose File...").tag("choose")
            }
            Button("Play") { player.play(feedback.wrappedValue.sound) }
                .accessibilityLabel("Play \(label.lowercased()) sound")
                .disabled(feedback.wrappedValue.sound == .none)
        }
        Toggle("\(label): speak", isOn: feedback.speak)
            .accessibilityLabel("\(label): speak")
        HStack {
            TextField("\(label) text", text: feedback.text)
            Button("Try") { player.speak(FeedbackText.render(feedback.wrappedValue.text, sample)) }
                .accessibilityLabel("Try \(label.lowercased()) text")
        }
    }

    private var sample: FeedbackValues {
        FeedbackValues(kind: OperationKindCatalog.info(kind ?? .copy), title: "Copy 3 items to Documents",
                       done: 2, total: 3, reason: "Permission denied")
    }

    private func binding(_ outcome: QueueOutcome) -> Binding<EventFeedback> {
        Binding(
            get: { store.settings.feedback.feedback(for: kind ?? .other, outcome) },
            set: { value in
                if let kind {
                    store.settings.feedback.setOverride(value, for: kind, outcome)
                } else {
                    store.settings.feedback.defaults[outcome.rawValue] = value
                }
            }
        )
    }

    private func soundBinding(_ feedback: Binding<EventFeedback>) -> Binding<String> {
        Binding(
            get: {
                switch feedback.wrappedValue.sound {
                case .none: "none"
                case .system(let name): "system:" + name
                case .file(let path): "file:" + path
                }
            },
            set: { tag in
                if tag == "none" {
                    feedback.wrappedValue.sound = .none
                } else if tag.hasPrefix("system:") {
                    feedback.wrappedValue.sound = .system(String(tag.dropFirst(7)))
                } else if tag.hasPrefix("file:") {
                    feedback.wrappedValue.sound = .file(String(tag.dropFirst(5)))
                } else if tag == "choose" {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.message = "Choose a sound file"
                    if panel.runModal() == .OK, let url = panel.url {
                        feedback.wrappedValue.sound = .file(url.path)
                        player.play(.file(url.path))
                    }
                }
            }
        )
    }
}
