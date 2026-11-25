import AppKit
import BasilCore
import SwiftUI

/// View Options (Cmd+J, like Finder's Show View Options): the active tab's view and columns,
/// sorting, folders on top, hidden files, date and size format. Every change applies at once and
/// is kept with the tab (also across restarts); what is not changed follows Settings.
@MainActor @Observable
final class ViewOptionsModel {
    @ObservationIgnored private weak var pane: PaneViewController?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored var onDone: (() -> Void)?

    let paneName: String
    private(set) var viewID = ""
    private(set) var columns: [ColumnSpec] = []
    private(set) var sortKey = SortKey.name
    private(set) var ascending = true
    private(set) var foldersFirst = true
    private(set) var showHidden = false
    private(set) var date = DateFormatSettings()
    private(set) var size = SizeFormat()
    /// The tab differs from the global settings (or its view's columns): Reset shows.
    private(set) var differs = false
    /// "Custom" chosen in the date pop-up while the pattern is still a preset's.
    var customDatePattern = false

    init(pane: PaneViewController, store: SettingsStore) {
        self.pane = pane
        self.store = store
        paneName = pane.side.accessibilityLabel
        load()
    }

    var views: [ListView] { store.settings.views }

    func load() {
        guard let pane else { return }
        let global = store.settings
        viewID = pane.viewID
        columns = pane.currentView.columns
        sortKey = pane.model.sortOrder.key
        ascending = pane.model.sortOrder.ascending
        foldersFirst = pane.effectiveFoldersFirst
        showHidden = pane.effectiveShowHidden
        date = pane.viewOptions.date ?? global.date
        size = pane.viewOptions.size ?? global.size
        differs = !pane.viewOptions.isEmpty
    }

    private func change(_ edit: (inout PaneViewOptions) -> Void) {
        guard let pane else { return }
        var options = pane.viewOptions
        edit(&options)
        pane.setViewOptions(options)
        load()
    }

    func setView(_ id: String) {
        pane?.setView(id, announce: false)
        load()
    }

    /// Columns the catalog has that the view does not list yet are offered after its own.
    var columnChoices: [ColumnSpec] {
        let missing = ColumnCatalog.all.map(\.id).filter { id in !columns.contains { $0.id == id } }
        return columns + missing.map { ColumnSpec($0, visible: false) }
    }

    func title(of id: ColumnID) -> String { ColumnCatalog.definition(id)?.title ?? id.rawValue }

    func setColumn(_ id: ColumnID, visible: Bool) {
        var list = columnChoices
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].isVisible = visible
        // Keep what the view had, plus a column just turned on.
        let kept = list.filter { spec in columns.contains { $0.id == spec.id } || spec.isVisible }
        change { $0.columns = kept }
    }

    func setSort(key: SortKey, ascending: Bool) {
        pane?.setSortOrder(key: key, ascending: ascending)
        load()
    }

    func setFoldersFirst(_ on: Bool) { change { $0.foldersFirst = on } }
    func setShowHidden(_ on: Bool) { change { $0.showHidden = on } }
    func setDate(_ value: DateFormatSettings) { change { $0.date = value } }
    func setSize(_ value: SizeFormat) { change { $0.size = value } }

    func reset() {
        guard let pane else { return }
        pane.setViewOptions(PaneViewOptions())
        customDatePattern = false
        load()
        pane.announceViewOptionsReset()
    }

    var dateExample: String {
        DisplayFormatters(size: size, date: date).date(Date().addingTimeInterval(-300))
            + ", " + DisplayFormatters(size: size, date: date).date(Date().addingTimeInterval(-30 * 86_400))
    }

    var sizeExample: String {
        [512, 1_536, 5_242_880, 3_221_225_472].map { size.string(Int64($0)) }.joined(separator: ", ")
    }
}

struct ViewOptionsView: View {
    @Bindable var model: ViewOptionsModel
    private static let customTag = "\u{0}custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View Options for this tab of the \(model.paneName.lowercased())")
                .font(.headline)
            Form {
                Section(header: Self.header("View and columns")) {
                    Picker("List view", selection: Binding(get: { model.viewID }, set: { model.setView($0) })) {
                        ForEach(model.views) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityLabel("List view")
                    ForEach(model.columnChoices.filter { $0.id != .name }, id: \.id) { spec in
                        let title = model.title(of: spec.id)
                        Toggle("Show \(title) column", isOn: Binding(
                            get: { spec.isVisible },
                            set: { model.setColumn(spec.id, visible: $0) }))
                            .accessibilityLabel("Show \(title) column")
                    }
                    Text("The Name column always shows. Choosing another view goes back to its own columns.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Section(header: Self.header("Sorting")) {
                    Picker("Sort by", selection: Binding(get: { model.sortKey },
                                                         set: { model.setSort(key: $0, ascending: model.ascending) })) {
                        ForEach(SortKey.allCases, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                    }
                    .accessibilityLabel("Sort by")
                    Picker("Order", selection: Binding(get: { model.ascending },
                                                       set: { model.setSort(key: model.sortKey, ascending: $0) })) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .accessibilityLabel("Order")
                    .disabled(model.sortKey == .unsorted)
                    Toggle("Folders on top", isOn: Binding(get: { model.foldersFirst }, set: { model.setFoldersFirst($0) }))
                        .accessibilityLabel("Folders on top")
                    Toggle("Show hidden files", isOn: Binding(get: { model.showHidden }, set: { model.setShowHidden($0) }))
                        .accessibilityLabel("Show hidden files")
                }
                Section(header: Self.header("Dates and sizes")) {
                    Picker("Date format", selection: datePresetBinding) {
                        ForEach(DateFormatSettings.presets, id: \.pattern) { Text($0.title).tag($0.pattern) }
                        Text("Custom").tag(Self.customTag)
                    }
                    .accessibilityLabel("Date format")
                    if isCustomPattern {
                        TextField("Pattern, for example yyyy-MM-dd", text: Binding(
                            get: { model.date.datePattern },
                            set: { var d = model.date; d.datePattern = $0; model.setDate(d) }))
                            .accessibilityLabel("Date pattern")
                    }
                    Picker("Time", selection: Binding(get: { model.date.time },
                                                      set: { var d = model.date; d.time = $0; model.setDate(d) })) {
                        ForEach(TimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityLabel("Time")
                    Toggle("Relative dates in the last week", isOn: Binding(
                        get: { model.date.relative },
                        set: { var d = model.date; d.relative = $0; model.setDate(d) }))
                        .accessibilityLabel("Relative dates in the last week")
                    Text("Example: \(model.dateExample)")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Picker("Size unit", selection: Binding(get: { model.size.unit },
                                                           set: { var s = model.size; s.unit = $0; model.setSize(s) })) {
                        ForEach(SizeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityLabel("Size unit")
                    Picker("1 KB equals", selection: Binding(get: { model.size.base },
                                                             set: { model.setSize(SizeFormat(unit: model.size.unit, base: $0)) })) {
                        Text("1024 bytes").tag(1024)
                        Text("1000 bytes").tag(1000)
                    }
                    .accessibilityLabel("1 KB equals")
                    Text("Examples: \(model.sizeExample)")
                        .foregroundStyle(Theme.secondaryTextColor)
                }
            }
            .formStyle(.grouped)
            // The scroll edges' blur made the audit misread the contrast of rows under them.
            .scrollEdgeEffectHidden(true, for: .all)
            HStack {
                if model.differs {
                    Button("Reset to Global Settings") { model.reset() }
                }
                Spacer()
                Button("Done") { model.onDone?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 640)
    }

    /// Section titles in the primary text colour: the grouped form's own grey failed the
    /// audit's contrast check in a sheet.
    static func header(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(.primary)
    }

    static func title(of key: SortKey) -> String {
        switch key {
        case .name: "Name"
        case .ext: "Extension"
        case .size: "Size"
        case .modified: "Date modified"
        case .created: "Date created"
        case .unsorted: "Unsorted"
        }
    }

    private var isCustomPattern: Bool {
        !DateFormatSettings.presets.contains { $0.pattern == model.date.datePattern } || model.customDatePattern
    }

    private var datePresetBinding: Binding<String> {
        Binding(
            get: { isCustomPattern ? Self.customTag : model.date.datePattern },
            set: { newValue in
                if newValue == Self.customTag {
                    model.customDatePattern = true
                } else {
                    model.customDatePattern = false
                    var d = model.date
                    d.datePattern = newValue
                    model.setDate(d)
                }
            })
    }
}

extension PaneViewController {
    /// View Options: sort by key and direction (spoken like the sort keys).
    func setSortOrder(key: SortKey, ascending: Bool) {
        // tableView(_:sortDescriptorsDidChange:) applies it.
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: key == .unsorted ? true : ascending)]
    }

    func announceViewOptionsReset() {
        delegate?.pane(self, announce: "Using global settings")
    }
}

extension MainWindowController {
    /// Cmd+J: View Options for the active pane's tab.
    func showViewOptions() {
        guard let window else { return }
        let pane = activePane
        let model = ViewOptionsModel(pane: pane, store: settings)
        let hosting = NSHostingController(rootView: ViewOptionsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("View Options")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "View Options"
        model.onDone = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        sheet.onCancel = { model.onDone?() }
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }
}
