import AppKit
import BasilCore
import BasilOperations
import BasilVFS
import SwiftUI

/// The split dialog (Files > Split > Split File, Total Commander's Split File).
@MainActor @Observable
final class SplitModel {
    let fileName: String
    let fileSize: Int64
    let sizeText: (Int64) -> String
    var targetPath: String
    var presetID: String
    var customSize: String
    var decimal: Bool
    var createSFV: Bool

    @ObservationIgnored var onSplit: ((SplitModel) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(fileName: String, fileSize: Int64, targetPath: String, settings: BasilSettings, sizeText: @escaping (Int64) -> String) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.targetPath = targetPath
        self.sizeText = sizeText
        presetID = SplitSizes.presets.contains { $0.id == settings.splitPreset } ? settings.splitPreset : "cd700"
        customSize = settings.splitCustomSize
        decimal = settings.splitDecimalUnits
        createSFV = settings.splitCreateSFV
    }

    var isCustom: Bool { presetID == "custom" }

    var partSize: Result<Int64, SplitSizes.ParseError> {
        if let bytes = SplitSizes.presets.first(where: { $0.id == presetID })?.bytes { return .success(bytes) }
        return SplitSizes.parse(customSize, decimal: decimal)
    }

    var problem: String? {
        if targetPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the folder for the parts." }
        switch partSize {
        case .failure(let error): return error.errorDescription
        case .success(let bytes):
            if fileSize <= bytes { return "\(fileName) is not larger than one part. Choose a smaller part size." }
            return nil
        }
    }

    /// "4 parts of 700 MB: movie.mkv.001 to movie.mkv.004"
    var summary: String? {
        guard problem == nil, case .success(let bytes) = partSize else { return nil }
        let count = SplitFileOperation.partCount(size: fileSize, partSize: bytes)
        let first = SplitFileOperation.partName(fileName, 1, count: count)
        let last = SplitFileOperation.partName(fileName, count, count: count)
        return "\(count) parts of \(sizeText(bytes)) (\(bytes) bytes): \(first) to \(last)"
    }
}

struct SplitView: View {
    @Bindable var model: SplitModel
    @FocusState private var targetFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split \(model.fileName), \(model.sizeText(model.fileSize))")
                .font(.headline)
            Form {
                TextField("Put the parts in", text: $model.targetPath)
                    .accessibilityLabel("Put the parts in")
                    .focused($targetFocused)
                Picker("Part size", selection: $model.presetID) {
                    ForEach(SplitSizes.presets) { Text($0.title).tag($0.id) }
                }
                .accessibilityLabel("Part size")
                if model.isCustom {
                    TextField("Custom size", text: $model.customSize, prompt: Text("For example 512 MB"))
                        .accessibilityLabel("Custom size")
                    Picker("Units", selection: $model.decimal) {
                        Text("Binary, 1 KB is 1024 bytes").tag(false)
                        Text("Decimal, 1 KB is 1000 bytes").tag(true)
                    }
                    .accessibilityLabel("Units")
                    Text("Type a number and a unit: bytes, KB, MB, GB or TB, for example 1 GB or 1.5 MB.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Toggle("Create SFV file", isOn: $model.createSFV)
                    .accessibilityLabel("Create SFV file")
                if model.createSFV {
                    Text("\(model.fileName).sfv lists a CRC32 for each part and for the whole file, so Combine Files can check the result.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                if let summary = model.summary {
                    Text(summary)
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
                Button("Split") { model.onSplit?(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.problem != nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { targetFocused = true }
    }
}

extension MainWindowController {
    /// Files > Split > Split File: the cursor file, into the other pane's folder.
    func splitFile() {
        guard let item = activePane.cursorItem else { return announce("No items") }
        guard case .file = item.kind else { return announce("Choose a file to split") }
        guard let window, ensureReadable(activePane.model.directory) else { return }
        let other = otherPane.model.directory
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        let folder = [other, activePane.model.directory].first { $0.location == .local } ?? home
        let sizeFormat = settings.settings.size
        let model = SplitModel(fileName: item.name, fileSize: item.size ?? 0, targetPath: folder.path,
                               settings: settings.settings, sizeText: { sizeFormat.string($0) })
        let hosting = NSHostingController(rootView: SplitView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("Split \(item.name)")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "Split File"
        let pane = activePane
        sheet.onCancel = { model.onCancel?() }
        model.onCancel = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        model.onSplit = { [weak self, weak window, weak sheet] model in
            if let sheet { window?.endSheet(sheet) }
            self?.queueSplit(item, model: model, from: pane)
        }
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }

    private func queueSplit(_ item: FileItem, model: SplitModel, from pane: PaneViewController) {
        guard let window, case .success(let partSize) = model.partSize,
              var target = resolve(model.targetPath, relativeTo: pane.model.directory) else { return }
        if target.location.container != nil { target = .local(target.path) }
        guard ensureWritable(target, archives: false) else { return }
        settings.settings.splitPreset = model.presetID
        settings.settings.splitCustomSize = model.customSize
        settings.settings.splitDecimalUnits = model.decimal
        settings.settings.splitCreateSFV = model.createSFV
        let count = SplitFileOperation.partCount(size: model.fileSize, partSize: partSize)
        let first = target.appending(SplitFileOperation.partName(item.name, 1, count: count))
        Task {
            if (try? await providers.provider(for: target.location).item(at: first)) != nil,
               await !confirm(in: window, message: "\(first.name) already exists in \(target.name). Replace the parts?",
                              confirm: "Replace") {
                return
            }
            let queued = queue.add(SplitFileOperation(source: item.path, target: target, partSize: partSize,
                                                      createSFV: model.createSFV, unstableRetries: settings.settings.unstableSourceRetries,
                                                      registry: providers))
            queued.whenDone = { [weak self] _ in
                guard let self else { return }
                for p in [left, right] where p.model.directory == target { p.model.reload(cursor: p.cursorPath) }
            }
        }
    }

    /// Files > Split > Combine Files: joins the parts the cursor file (any part, or the SFV) belongs
    /// to, by default into the other pane's folder.
    func combineFiles() {
        guard let item = activePane.cursorItem, case .file = item.kind else { return announce("Choose a part, such as name.001") }
        guard let window, ensureReadable(activePane.model.directory) else { return }
        let pane = activePane
        let other = otherPane.model.directory
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        let folder = [other, activePane.model.directory].first { $0.location == .local } ?? home
        Task {
            let set: SplitSet
            do {
                set = try await CombineFilesOperation.parts(of: item.path, registry: providers)
            } catch {
                return pane.report(error.localizedDescription)
            }
            let checked = set.info?.source.map { ", checked with \($0.name)" } ?? ", not checked: no SFV file"
            guard let text = await askText(in: window, message: "Combine \(set.parts.count) parts\(checked), into:",
                                           initial: folder.appending(set.outputName).path,
                                           confirm: "Combine", fieldLabel: "Combined file"),
                  var destination = resolve(text, relativeTo: pane.model.directory) else { return }
            if destination.location.container != nil { destination = .local(destination.path) }
            if (try? await providers.provider(for: destination.location).item(at: destination))?.isDirectoryLike == true {
                destination = destination.appending(set.outputName)
            }
            guard let parent = destination.parent, ensureWritable(parent, archives: false) else { return }
            if (try? await providers.provider(for: destination.location).item(at: destination)) != nil,
               await !confirm(in: window, message: "\(destination.name) already exists. Replace it?", confirm: "Replace") {
                return
            }
            let queued = queue.add(CombineFilesOperation(set: set, destination: destination, registry: providers))
            queued.whenDone = { [weak self] state in
                guard let self else { return }
                for p in [left, right] where p.model.directory == parent {
                    p.model.reload(cursor: state == .finished ? destination : p.cursorPath)
                }
            }
        }
    }
}
