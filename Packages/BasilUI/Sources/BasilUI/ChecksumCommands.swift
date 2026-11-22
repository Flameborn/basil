import AppKit
import BasilCore
import BasilOperations

/// Files > Checksums, like Total Commander's Create Checksum Files and Verify Checksums.
extension MainWindowController {
    /// Hashes the selected (or cursor) items into one checksum file in the current folder, or into
    /// one checksum file next to each file.
    func createChecksums() {
        guard let window, ensureReadable(activePane.model.directory),
              ensureWritable(activePane.model.directory, archives: false) else { return }
        let pane = activePane
        let items = targetItems
        guard !items.isEmpty else { return announce("No items") }
        let directory = pane.model.directory
        let baseName = items.count == 1 ? items[0].name : directory.displayName
        Task {
            guard let answer = await askChecksumOptions(in: window, baseName: baseName) else { return }
            settings.settings.checksumAlgorithm = answer.algorithm.rawValue
            let output: CreateChecksumsOperation.Output
            var cursor: VFSPath?
            if answer.perFile {
                output = .perFile
            } else {
                guard let target = resolve(answer.name, relativeTo: directory) else { return }
                if (try? await providers.provider(for: target.location).item(at: target)) != nil,
                   await !confirm(in: window, message: "\(target.name) already exists. Replace it?", confirm: "Replace") {
                    return
                }
                output = .single(target)
                cursor = target
            }
            let queued = queue.add(CreateChecksumsOperation(items: items, directory: directory, algorithm: answer.algorithm,
                                                            output: output, registry: providers))
            pane.model.deselectAll()
            queued.whenDone = { _ in
                if pane.model.directory == directory { pane.model.reload(cursor: cursor ?? pane.cursorPath) }
            }
        }
    }

    /// Checks the selected (or cursor) checksum files.
    func verifyChecksums() {
        let files = targetItems.filter { !$0.isDirectoryLike && ChecksumAlgorithm.isChecksumFile($0.name) }
        guard !files.isEmpty else { return announce("No checksum files") }
        queue.add(VerifyChecksumsOperation(checksumFiles: files.map(\.path), registry: providers))
        activePane.model.deselectAll()
    }

    private struct ChecksumAnswer {
        let algorithm: ChecksumAlgorithm
        let perFile: Bool
        let name: String
    }

    private func askChecksumOptions(in window: NSWindow, baseName: String) async -> ChecksumAnswer? {
        let alert = NSAlert()
        alert.messageText = "Create checksum files:"
        alert.informativeText = "Files in selected folders are included, with their paths."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 420
        let algorithms = ChecksumAlgorithm.allCases
        let current = ChecksumAlgorithm(rawValue: settings.settings.checksumAlgorithm) ?? .sha256
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: width, height: 26), pullsDown: false)
        popup.addItems(withTitles: algorithms.map(\.title))
        popup.selectItem(at: algorithms.firstIndex(of: current) ?? 0)
        popup.setAccessibilityLabel("Algorithm")
        let perFile = NSButton(checkboxWithTitle: "One checksum file per file", target: nil, action: nil)
        perFile.frame = NSRect(x: 0, y: 34, width: width, height: 22)
        let field = NSTextField(string: "\(baseName).\(current.fileExtension)")
        field.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        field.setAccessibilityLabel("Checksum file")

        // Changing the algorithm changes the extension; one file per file needs no name.
        let handler = ChecksumSheetHandler(popup: popup, perFile: perFile, field: field, baseName: baseName)
        popup.target = handler
        popup.action = #selector(ChecksumSheetHandler.changed(_:))
        perFile.target = handler
        perFile.action = #selector(ChecksumSheetHandler.changed(_:))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 88))
        [popup, perFile, field].forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = popup

        let confirmed: Bool = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            alert.window.makeFirstResponder(popup)
        }
        _ = handler
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard confirmed, perFile.state == .on || !name.isEmpty else { return nil }
        return ChecksumAnswer(algorithm: algorithms[popup.indexOfSelectedItem], perFile: perFile.state == .on, name: name)
    }

    func confirm(in window: NSWindow, message: String, confirm: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }
}

@MainActor
private final class ChecksumSheetHandler: NSObject {
    let popup: NSPopUpButton
    let perFile: NSButton
    let field: NSTextField
    let baseName: String

    init(popup: NSPopUpButton, perFile: NSButton, field: NSTextField, baseName: String) {
        self.popup = popup
        self.perFile = perFile
        self.field = field
        self.baseName = baseName
    }

    @objc func changed(_ sender: Any?) {
        let algorithm = ChecksumAlgorithm.allCases[popup.indexOfSelectedItem]
        // Keep a name the user typed; only swap a known checksum extension.
        var name = field.stringValue
        if let dot = name.lastIndex(of: "."), ChecksumAlgorithm.isChecksumFile(name) { name = String(name[..<dot]) }
        field.stringValue = "\(name.isEmpty ? baseName : name).\(algorithm.fileExtension)"
        field.isEnabled = perFile.state == .off
    }
}
