import AppKit
import BasilCore
import BasilGit
import BasilOperations

/// Commands > Git > Branches...: the repository's local branches, then its remote ones, one
/// sentence per row ("main, current, up to date with origin/main, Fix the parser, 2 days ago").
///
/// Return checks out (a queue item: it changes files; a remote branch becomes the local branch
/// tracking it), Cmd+N makes a new branch, Shift+F6 renames, Delete deletes (asks; an unmerged
/// branch asks a second time), Merge into Current is a queue item, Fetch updates the remote
/// branches. New, rename and delete run at once (only git's database changes).
@MainActor
final class BranchesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [String: BranchesWindowController] = [:]

    static func show(root: String, git: GitService, controller: MainWindowController) {
        let window = open[root] ?? BranchesWindowController(root: root, git: git, controller: controller)
        open[root] = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(window.table)
        window.reload()
    }

    static func refreshAll() {
        for window in open.values { window.reload() }
    }

    let root: String
    private let git: GitService
    private weak var controller: MainWindowController?
    private var branches: [GitBranch] = []
    private var generation = 0
    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private let summary = NSTextField(wrappingLabelWithString: "Reading branches")
    fileprivate let table = CompareTableView()
    private let checkoutButton = NSButton(title: "Check Out", target: nil, action: nil)
    private let newButton = NSButton(title: "New Branch...", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename Branch...", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Branch...", target: nil, action: nil)
    private let mergeButton = NSButton(title: "Merge into Current...", target: nil, action: nil)
    private let fetchButton = NSButton(title: "Fetch", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private init(root: String, git: GitService, controller: MainWindowController) {
        self.root = root
        self.git = git
        self.controller = controller
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Branches of \((root as NSString).lastPathComponent)"
        window.basilAutosave("BasilBranchesWindow")
        window.contentMinSize = NSSize(width: 700, height: 360)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        buildContent()
        if !window.setFrameUsingName("BasilBranchesWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { Self.open[root] = nil }
    func windowDidBecomeKey(_ notification: Notification) { reload() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summary.setAccessibilityLabel("Repository")
        summary.setAccessibilityIdentifier("branches.summary")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Branch"))
        column.title = "Branch"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = Theme.rowHeight + 2
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.setAccessibilityLabel("Branches")
        table.setAccessibilityIdentifier("branches.table")
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(checkout)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        for (button, action, help) in [(checkoutButton, #selector(checkout), "Return"), (newButton, #selector(newBranch), "Cmd+N"),
                                       (renameButton, #selector(rename), "Shift+F6"), (deleteButton, #selector(delete), "Delete"),
                                       (mergeButton, #selector(merge), nil), (fetchButton, #selector(fetch), nil),
                                       (closeButton, #selector(closeWindow), "Escape")] as [(NSButton, Selector, String?)] {
            button.target = self
            button.action = action
            if let help { button.setAccessibilityHelp(help) }
        }
        let buttons = NSStackView(views: [checkoutButton, newButton, renameButton, deleteButton, mergeButton, fetchButton,
                                          NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [summary, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    // MARK: Reading

    func reload() {
        generation += 1
        let generation = generation, git = git, root = root
        Task {
            do {
                let new = try await git.branches(root: root)
                guard generation == self.generation else { return }
                apply(new)
            } catch {
                guard generation == self.generation else { return }
                summary.stringValue = "Could not read the branches: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ new: [GitBranch]) {
        let selected = selectedBranch?.id
        branches = new
        table.reloadData()
        let row = selected.flatMap { id in branches.firstIndex { $0.id == id } } ?? branches.firstIndex { $0.isCurrent } ?? 0
        if !branches.isEmpty { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let current = branches.first { $0.isCurrent }?.name ?? "detached HEAD"
        let locals = branches.filter { !$0.isRemote }.count
        summary.stringValue = "\((root as NSString).lastPathComponent), on \(current), \(locals) local and \(branches.count - locals) remote branches"
        updateButtons()
    }

    private var selectedBranch: GitBranch? {
        let row = table.selectedRow
        return branches.indices.contains(row) ? branches[row] : nil
    }

    private var currentName: String? { branches.first { $0.isCurrent }?.name }

    private func updateButtons() {
        let branch = selectedBranch
        checkoutButton.isEnabled = branch.map { !$0.isCurrent } ?? false
        renameButton.isEnabled = branch.map { !$0.isRemote } ?? false
        deleteButton.isEnabled = branch.map { !$0.isRemote && !$0.isCurrent } ?? false
        mergeButton.isEnabled = branch.map { !$0.isCurrent } ?? false && currentName != nil
    }

    private func tracking(_ branch: GitBranch) -> String {
        guard !branch.isRemote else { return "" }
        guard let upstream = branch.upstream else { return "local only" }
        if branch.upstreamGone { return "\(upstream) is gone" }
        switch (branch.ahead, branch.behind) {
        case (0, 0): return "up to date with \(upstream)"
        case (let a, 0): return "\(a) ahead of \(upstream)"
        case (0, let b): return "\(b) behind \(upstream)"
        case (let a, let b): return "\(a) ahead and \(b) behind \(upstream)"
        }
    }

    private func cells(_ branch: GitBranch) -> [String] {
        let state = branch.isCurrent ? "current" : (branch.isRemote ? "remote" : "")
        let date = branch.date.map { relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        return [branch.name, state, tracking(branch), branch.subject, date]
    }

    private func spoken(_ branch: GitBranch) -> String {
        cells(branch).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { branches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let branch = branches[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("branch")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: [220, 64, 230, nil, 120], flexibleFont: Theme.listFont)
        cell.show(cells(branch), spoken: spoken(branch))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompareRowBackground()
        if branches[safe: row]?.isCurrent == true { view.status = .changed }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    @objc private func checkout() {
        guard let branch = selectedBranch, !branch.isCurrent, let controller else { return }
        let item = controller.queue.add(GitBranchOperation(.checkout(branch), root: root, git: git))
        item.whenDone = { [weak controller] _ in controller?.gitStateChanged() }
    }

    @objc private func merge() {
        guard let branch = selectedBranch, !branch.isCurrent, let current = currentName, let window, let controller else { return }
        let alert = NSAlert()
        alert.messageText = "Merge \(branch.name) into \(current)?"
        alert.informativeText = "Conflicts, if any, show up in the Git column and the Commit window."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        let root = root, git = git
        Task {
            guard await controller.present(alert, in: window) == 0 else { return }
            let item = controller.queue.add(GitBranchOperation(.merge(branch, into: current), root: root, git: git))
            item.whenDone = { [weak controller] _ in controller?.gitStateChanged() }
        }
    }

    @objc private func fetch() {
        controller?.queueGitRemote(.fetch, root: root)
    }

    @objc private func newBranch() {
        guard let window, let controller else { return }
        let alert = NSAlert()
        alert.messageText = "New branch from \(currentName ?? "the current commit")"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        field.setAccessibilityLabel("Branch name")
        let switchBox = NSButton(checkboxWithTitle: "Switch to the new branch", target: nil, action: nil)
        switchBox.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        switchBox.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(switchBox)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        let git = git, root = root
        Task {
            let confirmed: Bool = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                alert.window.makeFirstResponder(field)
            }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard confirmed, !name.isEmpty else { return }
            guard await git.isValidBranchName(name, root: root) else { return controller.announce("\(name) is not a valid branch name") }
            do {
                try await git.createBranch(name, switchTo: switchBox.state == .on, root: root)
                controller.announce(switchBox.state == .on ? "Created and switched to \(name)" : "Created \(name)")
                controller.gitStateChanged()
            } catch {
                controller.announce("Could not create \(name): \(error.localizedDescription)")
            }
        }
    }

    @objc private func rename() {
        guard let branch = selectedBranch, !branch.isRemote, let window, let controller else { return }
        let git = git, root = root
        Task {
            guard let name = await controller.askText(in: window, message: "Rename \(branch.name) to:", initial: branch.name,
                                                      confirm: "Rename", fieldLabel: "New name")?
                .trimmingCharacters(in: .whitespaces), !name.isEmpty, name != branch.name else { return }
            guard await git.isValidBranchName(name, root: root) else { return controller.announce("\(name) is not a valid branch name") }
            do {
                try await git.renameBranch(branch.name, to: name, root: root)
                controller.announce("Renamed to \(name)")
                controller.gitStateChanged()
            } catch {
                controller.announce("Could not rename \(branch.name): \(error.localizedDescription)")
            }
        }
    }

    @objc private func delete() {
        guard let branch = selectedBranch, !branch.isRemote, !branch.isCurrent, let window, let controller else { return }
        let git = git, root = root
        Task {
            let alert = NSAlert()
            alert.messageText = "Delete the branch \(branch.name)?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard await controller.present(alert, in: window) == 0 else { return }
            do {
                try await git.deleteBranch(branch.name, force: false, root: root)
            } catch let error as GitError where error.isNotMerged {
                let again = NSAlert()
                again.alertStyle = .warning
                again.messageText = "\(branch.name) has commits that are not merged"
                again.informativeText = "Deleting it loses those commits unless another branch has them. Delete it anyway?"
                again.addButton(withTitle: "Cancel")
                again.addButton(withTitle: "Delete Anyway")
                guard await controller.present(again, in: window) == 1 else { return }
                do {
                    try await git.deleteBranch(branch.name, force: true, root: root)
                } catch {
                    return controller.announce("Could not delete \(branch.name): \(error.localizedDescription)")
                }
            } catch {
                return controller.announce("Could not delete \(branch.name): \(error.localizedDescription)")
            }
            controller.announce("Deleted \(branch.name)")
            controller.gitStateChanged()
        }
    }

    @objc private func closeWindow() { window?.close() }

    private func handle(_ chord: KeyChord) -> Bool {
        let inTable = window?.firstResponder === table
        switch chord {
        case KeyChord(.escape), KeyChord(.character("w"), .command): closeWindow()
        case KeyChord(.enter) where inTable: checkout()
        case KeyChord(.character("n"), .command): newBranch()
        case KeyChord(.function(6), .shift) where inTable: rename()
        case KeyChord(.backspace) where inTable, KeyChord(.forwardDelete) where inTable: delete()
        default: return false
        }
        return true
    }
}
