import AppKit
import BasilCore
import BasilIntegrations
import BasilVFS
import SwiftUI
import UniformTypeIdentifiers

/// Cmd+I: Basil's own Get Info sheet for the cursor item. Shows name, kind, size (a folder's size
/// is calculated), location, dates, permissions and owner, and for files the app that opens them,
/// which can be made the default for all files of that type (Finder's "Change All").
@MainActor
@Observable
final class InfoModel {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let item: FileItem
    private let formatters: DisplayFormatters
    private(set) var size = ""
    private(set) var apps: [FileAssociations.App] = []
    private(set) var defaultApp: FileAssociations.App?
    var chosenApp: URL?
    private(set) var message = ""
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var announce: ((String) -> Void)?

    private var url: URL? { item.path.location == .local ? URL(fileURLWithPath: item.path.path) : nil }
    var contentType: UTType? { url.flatMap(FileAssociations.contentType(of:)) }
    var isFile: Bool { !item.isDirectoryLike && url != nil }

    init(item: FileItem, formatters: DisplayFormatters, registry: ProviderRegistry) {
        self.item = item
        self.formatters = formatters
        if item.isDirectoryLike {
            size = item.size.map { "\(formatters.size.string($0)), calculated before" } ?? "Calculating..."
            let path = item.path
            sizeTask = Task { [weak self] in
                guard let provider = try? registry.provider(for: path.location) else { return }
                let walk = Task.detached(priority: .userInitiated) { try await provider.totals(of: path) }
                let totals = await withTaskCancellationHandler { try? await walk.value } onCancel: { walk.cancel() }
                guard let self, let totals else { return }
                self.size = self.describe(totals)
            }
        } else {
            size = item.size.map(bytesText) ?? "Unknown"
        }
        if isFile, let url {
            let found = FileAssociations.apps(toOpen: url)
            apps = found.all
            defaultApp = found.defaultApp
            chosenApp = found.defaultApp?.url
        }
    }

    isolated deinit { sizeTask?.cancel() }

    func stop() { sizeTask?.cancel() }

    private func bytesText(_ bytes: Int64) -> String {
        let text = formatters.size.string(bytes)
        return text.contains("bytes") ? text : "\(text) (\(bytes.formatted()) bytes)"
    }

    private func describe(_ t: DirectoryTotals) -> String {
        func count(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }
        var text = "\(bytesText(t.bytes)), \(count(t.files, "file")), \(count(t.folders, "folder"))"
        if t.unreadable > 0 { text += ", \(count(t.unreadable, "folder")) could not be read" }
        return text
    }

    var rows: [Row] {
        var rows = [Row(label: "Name", value: item.name)]
        let kind = url.flatMap { try? $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription }
        rows.append(Row(label: "Kind", value: kind ?? (item.isDirectoryLike ? "Folder" : "File")))
        rows.append(Row(label: "Size", value: size))
        rows.append(Row(label: "Where", value: item.path.parent?.description ?? "/"))
        if case .symlink = item.kind, let url,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            rows.append(Row(label: "Link to", value: target))
        }
        rows.append(Row(label: "Created", value: formatters.date(item.created)))
        rows.append(Row(label: "Modified", value: formatters.date(item.modified)))
        rows.append(Row(label: "Permissions", value: Attributes.string(item)))
        if let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let owner = attributes[.ownerAccountName] as? String ?? "unknown"
            let group = attributes[.groupOwnerAccountName] as? String ?? "unknown"
            rows.append(Row(label: "Owner", value: "\(owner), group \(group)"))
        }
        return rows
    }

    /// "Use for All MP3 Files", from the extension when there is one.
    var changeAllTitle: String {
        let ext = item.nameAndExtension.ext
        return ext.isEmpty ? "Use for All Files of This Kind" : "Use for All .\(ext) Files"
    }

    var canChangeAll: Bool { chosenApp != nil && chosenApp != defaultApp?.url && contentType != nil }

    func changeAll() {
        guard let app = chosenApp, let type = contentType else { return }
        let name = apps.first { $0.url == app }?.name ?? app.lastPathComponent
        Task {
            do {
                try await FileAssociations.setDefault(app, for: type)
                defaultApp = apps.first { $0.url == app }
                message = "\(name) now opens all files of this kind"
            } catch {
                message = "Could not change the default app: \(error.localizedDescription)"
            }
            announce?(message)
        }
    }
}

struct InfoView: View {
    @Bindable var model: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                ForEach(model.rows) { row in
                    // One static text per row ("Size, 1.2 MB"); the visible label is not read separately.
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .frame(width: 96, alignment: .leading)
                            .accessibilityHidden(true)
                        Text(row.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(row.label)
                            .accessibilityValue(row.value)
                    }
                }
                if model.isFile {
                    Picker("Open with", selection: $model.chosenApp) {
                        ForEach(model.apps) { app in
                            Text(app.url == model.defaultApp?.url ? "\(app.name) (default)" : app.name)
                                .tag(Optional(app.url))
                        }
                    }
                    .disabled(model.apps.isEmpty)
                    .accessibilityLabel("Open with")
                    Button(model.changeAllTitle) { model.changeAll() }
                        .disabled(!model.canChangeAll)
                    if !model.message.isEmpty {
                        Text(model.message).foregroundStyle(Theme.secondaryTextColor)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

extension MainWindowController {
    /// Cmd+I: the Info sheet for the cursor item.
    func showInfo() {
        guard let window else { return }
        guard let item = activePane.cursorItem else { return announce("No items") }
        let model = InfoModel(item: item, formatters: settings.formatters, registry: providers)
        model.announce = { [weak self] in self?.announce($0) }
        let hosting = NSHostingController(rootView: InfoView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("Info for \(item.name)")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "Info for \(item.name)"
        sheet.onCancel = { model.onClose?() }
        model.onClose = { [weak window, weak sheet, weak model] in
            model?.stop()
            if let sheet { window?.endSheet(sheet) }
        }
        let pane = activePane
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }
}

/// A sheet window that closes on Escape (wherever focus is inside it).
final class EscapableSheet: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
