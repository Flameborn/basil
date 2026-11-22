import AppKit
import BasilCore
import BasilOperations
import BasilVFS
import SwiftUI

/// The unpack dialog (Option+F9, Total Commander's Alt+F9).
@MainActor @Observable
final class UnpackModel {
    let what: String
    var targetPath: String
    var ownFolder: Bool
    var mask: String
    var paths: Bool
    var deleteAfter = false
    var deletePermanently: Bool

    @ObservationIgnored var onUnpack: ((UnpackModel) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(what: String, targetPath: String, settings: BasilSettings) {
        self.what = what
        self.targetPath = targetPath
        ownFolder = settings.unpackOwnFolder
        mask = settings.unpackMask
        paths = settings.unpackPaths
        deletePermanently = settings.unpackDeletePermanently
    }

    var problem: String? {
        if targetPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the folder to unpack into." }
        return nil
    }
}

struct UnpackView: View {
    @Bindable var model: UnpackModel
    @FocusState private var targetFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unpack \(model.what)")
                .font(.headline)
            Form {
                TextField("Unpack to", text: $model.targetPath)
                    .accessibilityLabel("Unpack to")
                    .focused($targetFocused)
                Toggle("Extract into its own folder when the archive has several items at the top", isOn: $model.ownFolder)
                    .accessibilityLabel("Extract into its own folder when the archive has several items at the top")
                if model.ownFolder {
                    Text("An archive with one folder or one file at the top is unpacked as it is; one with several items gets a folder named after the archive.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                TextField("Only files matching", text: $model.mask, prompt: Text("All files"))
                    .accessibilityLabel("Only files matching")
                Text("Leave empty for all files, or type masks like *.jpg;*.png, with exclusions after |.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
                Toggle("Unpack folder paths", isOn: $model.paths)
                    .accessibilityLabel("Unpack folder paths")
                if !model.paths {
                    Text("Every file goes straight into the target folder, without the folders it is in.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Toggle("Delete archive after unpacking", isOn: $model.deleteAfter)
                    .accessibilityLabel("Delete archive after unpacking")
                Picker("How to delete", selection: $model.deletePermanently) {
                    Text("Move to Trash").tag(false)
                    Text("Delete permanently").tag(true)
                }
                .accessibilityLabel("How to delete")
                .disabled(!model.deleteAfter)
                if model.deleteAfter {
                    Text("The archive is deleted only when everything in it was unpacked without errors or skipped files. All volumes of a multi-volume archive are deleted.")
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
                Button("Unpack") { model.onUnpack?(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.problem != nil)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { targetFocused = true }
    }
}

extension MainWindowController {
    /// Option+F9: unpacks the selected archives (or the cursor archive), by default into the other
    /// pane's folder.
    func unpackArchives() {
        let archives = targetItems.filter { item in
            guard case .file = item.kind else { return false }
            return providers.containerOpener(forFile: item.path) != nil
        }
        guard !archives.isEmpty else { return announce("No archives") }
        guard let window else { return }
        let other = otherPane.model.directory
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        let folder = [other, activePane.model.directory].first { $0.location == .local } ?? home
        let what = archives.count == 1 ? archives[0].name : "\(archives.count) archives"
        let model = UnpackModel(what: what, targetPath: folder.path, settings: settings.settings)
        let hosting = NSHostingController(rootView: UnpackView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("Unpack \(what)")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "Unpack"
        let pane = activePane
        sheet.onCancel = { model.onCancel?() }
        model.onCancel = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        model.onUnpack = { [weak self, weak window, weak sheet] model in
            if let sheet { window?.endSheet(sheet) }
            self?.queueUnpack(archives, model: model, from: pane)
        }
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }

    private func queueUnpack(_ archives: [FileItem], model: UnpackModel, from pane: PaneViewController) {
        guard var target = resolve(model.targetPath, relativeTo: pane.model.directory) else { return }
        if target.location.container != nil { target = .local(target.path) }
        guard ensureWritable(target, archives: false) else { return }
        settings.settings.unpackOwnFolder = model.ownFolder
        settings.settings.unpackMask = model.mask
        settings.settings.unpackPaths = model.paths
        settings.settings.unpackDeletePermanently = model.deletePermanently
        let s = settings.settings
        let options = UnpackOperation.Options(
            ownFolder: model.ownFolder, mask: model.mask, paths: model.paths,
            deleteAfter: model.deleteAfter ? (model.deletePermanently ? .permanently : .trash) : nil,
            copy: SecureCopyOptions(verifyDestination: s.verifyCopies, unstableRetries: s.unstableSourceRetries, secure: s.secureCopy))
        let queued = queue.add(UnpackOperation(archives: archives.map(\.path), target: target, options: options, registry: providers))
        pane.model.deselectAll()
        queued.whenDone = { [weak self] _ in
            guard let self else { return }
            for p in [left, right] where p.model.directory.location == target.location {
                p.model.reload(cursor: p.cursorPath)
            }
        }
    }
}
