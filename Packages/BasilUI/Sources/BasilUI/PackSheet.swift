import AppKit
import BasilCore
import BasilOperations
import BasilVFS
import SwiftUI

/// The pack dialog (Option+F5, Total Commander's Alt+F5).
@MainActor @Observable
final class PackModel {
    let what: String
    let formats: [PackFormat]
    var archivePath: String
    var formatID: String {
        didSet { replaceExtension(old: oldValue, new: formatID) }
    }
    var level: PackLevel
    var moveToArchive = false
    var perItem = false
    var storePaths = true
    var testAfterPacking = false
    /// Whether any item is a folder (a single compressed file can't hold one).
    let hasFolders: Bool
    let itemCount: Int

    @ObservationIgnored var onPack: ((PackModel) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(what: String, formats: [PackFormat], archivePath: String, formatID: String, level: PackLevel,
         hasFolders: Bool, itemCount: Int) {
        self.what = what
        self.formats = formats
        self.archivePath = archivePath
        self.formatID = formatID
        self.level = level
        self.hasFolders = hasFolders
        self.itemCount = itemCount
    }

    var format: PackFormat? { formats.first { $0.id == formatID } }

    /// Why Pack is disabled, if it is.
    var problem: String? {
        if archivePath.trimmingCharacters(in: .whitespaces).isEmpty { return "Type a name for the archive." }
        if let format, format.singleFile {
            if hasFolders { return "\(format.name) holds one file; folders cannot be packed into it." }
            if itemCount > 1, !perItem { return "\(format.name) holds one file. Turn on One archive per item." }
        }
        return nil
    }

    private func replaceExtension(old: String, new: String) {
        let suffix = "." + old
        if archivePath.lowercased().hasSuffix(suffix) {
            archivePath = String(archivePath.dropLast(suffix.count)) + "." + new
        }
        if let format, !format.levels.isEmpty, !format.levels.contains(level) { level = .normal }
    }
}

struct PackView: View {
    @Bindable var model: PackModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pack \(model.what)")
                .font(.headline)
            Form {
                TextField("Archive", text: $model.archivePath)
                    .accessibilityLabel("Archive")
                    .focused($nameFocused)
                Picker("Format", selection: $model.formatID) {
                    ForEach(model.formats) { Text($0.name).tag($0.id) }
                }
                .accessibilityLabel("Format")
                if let levels = model.format?.levels, !levels.isEmpty {
                    Picker("Compression", selection: $model.level) {
                        ForEach(levels, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityLabel("Compression")
                }
                Toggle("Store folder paths", isOn: $model.storePaths)
                    .accessibilityLabel("Store folder paths")
                Toggle("One archive per item", isOn: $model.perItem)
                    .accessibilityLabel("One archive per item")
                Toggle("Move to archive", isOn: $model.moveToArchive)
                    .accessibilityLabel("Move to archive")
                Toggle("Test archive after packing", isOn: $model.testAfterPacking)
                    .accessibilityLabel("Test archive after packing")
                if model.perItem {
                    Text("Each item is packed into its own archive, named after it, in the folder of the archive above.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                if model.moveToArchive {
                    Text("The items are deleted once the archive is written and checked.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                if let problem = model.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(Theme.errorTextColor)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Pack") { model.onPack?(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.problem != nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { nameFocused = true }
    }
}

extension MainWindowController {
    /// Option+F5: packs the selected items (or the cursor item) into an archive, by default in
    /// the other pane's folder.
    func packItems() {
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        guard let window else { return }
        let formats = providers.packFormats
        guard !formats.isEmpty else { return announce("No archive formats available") }
        let s = settings.settings
        let formatID = formats.contains { $0.id == s.packFormat } ? s.packFormat : formats[0].id
        let level = PackLevel(rawValue: s.packLevel) ?? .normal
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        let folder = [otherPane.model.directory, activePane.model.directory].first { $0.location == .local } ?? home
        let base = items.count == 1 ? Self.archiveBaseName(items[0])
            : (activePane.model.directory.isRoot ? "Archive" : activePane.model.directory.displayName)
        let what = items.count == 1 ? items[0].name : FeedbackText.items(items.count)
        let model = PackModel(what: what, formats: formats,
                              archivePath: folder.appending(base + "." + formatID).path,
                              formatID: formatID, level: level,
                              hasFolders: items.contains { $0.isDirectoryLike }, itemCount: items.count)
        model.testAfterPacking = s.packTestAfter
        let hosting = NSHostingController(rootView: PackView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("Pack \(what)")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "Pack"
        let pane = activePane
        sheet.onCancel = { model.onCancel?() }
        model.onCancel = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        model.onPack = { [weak self, weak window, weak sheet] model in
            if let sheet { window?.endSheet(sheet) }
            self?.queuePack(items, model: model, from: pane)
        }
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }

    /// "Photos" for a folder, "notes" for notes.txt.
    static func archiveBaseName(_ item: FileItem) -> String {
        item.isDirectoryLike ? item.name : item.nameAndExtension.base
    }

    private func queuePack(_ items: [FileItem], model: PackModel, from pane: PaneViewController) {
        guard var archive = resolve(model.archivePath, relativeTo: pane.model.directory) else { return }
        if archive.location != .local { archive = .local(archive.path) }
        settings.settings.packFormat = model.formatID
        settings.settings.packLevel = model.level.rawValue
        settings.settings.packTestAfter = model.testAfterPacking
        let jobs: [PackOperation.Job]
        if model.perItem, let folder = archive.parent {
            jobs = items.map { PackOperation.Job(archive: folder.appending(Self.archiveBaseName($0) + "." + model.formatID),
                                                 sources: [$0.path]) }
        } else {
            jobs = [PackOperation.Job(archive: archive, sources: items.map(\.path))]
        }
        let s = settings.settings
        let options = PackOptions(format: model.formatID, level: model.level, macMetadata: s.packMacMetadata)
        let queued = queue.add(PackOperation(jobs: jobs, options: options, storePaths: model.storePaths,
                                             moveSources: model.moveToArchive, unstableRetries: s.unstableSourceRetries,
                                             registry: providers))
        pane.model.deselectAll()
        let test = model.testAfterPacking
        queued.whenDone = { [weak self] state in
            guard let self else { return }
            for job in jobs { reloadPanes(showingArchive: job.archive) }
            // A separate Test Archive item, with its own result, sound and speech.
            if test, state == .finished {
                queue.add(TestArchiveOperation(archives: jobs.map(\.archive), registry: providers))
            }
        }
    }

    /// Rereads panes that show the inside of `archive` (archives are not watched).
    func reloadPanes(showingArchive archive: VFSPath) {
        for pane in [left, right] where pane.model.directory.location.container == archive {
            pane.model.reload(cursor: pane.cursorPath)
        }
    }
}
