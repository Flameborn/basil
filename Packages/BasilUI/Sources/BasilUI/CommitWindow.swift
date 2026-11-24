import AppKit
import BasilCore
import BasilGit
import BasilOperations
import BasilVFS

/// Commands > Git > Commit...: every change of one repository, made for VoiceOver.
///
/// - Changes: one row per file, read as one sentence ("src/main.swift, Modified, not staged").
///   Space stages or unstages the selected rows (several with Shift or Cmd).
/// - Diff: the cursor file against the last commit, one row per line ("Added, line 12: ...").
/// - Message, Amend last commit (fills in the last message), Push after committing (remembered).
/// - Buttons: Stage All, Discard Changes (asks; a queue item), Commit (Cmd+Return), Close (Escape).
///
/// Staging and committing run at once (only git's database changes); Discard and Push are
/// queue items (user's decision, 2026-11-24). One window per repository.
@MainActor
final class CommitWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [String: CommitWindowController] = [:]

    static func show(root: String, git: GitService, controller: MainWindowController) {
        let window = open[root] ?? CommitWindowController(root: root, git: git, controller: controller)
        open[root] = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(window.changesTable)
        window.reload()
    }

    /// Rereads every open Commit window (after a queue item, a pull, ...).
    static func refreshAll() {
        for window in open.values { window.reload() }
    }

    let root: String
    private let git: GitService
    private weak var controller: MainWindowController?
    private var status = GitStatus()
    private var changes: [GitStatus.Entry] = []
    private var diff: GitDiff?
    private var loadGeneration = 0
    private var diffGeneration = 0

    private let summary = NSTextField(wrappingLabelWithString: "Reading changes")
    fileprivate let changesTable = CompareTableView()
    private let diffTable = CompareTableView()
    private let diffNote = NSTextField(labelWithString: "")
    private let messageView = NSTextView()
    private let amendBox = NSButton(checkboxWithTitle: "Amend last commit", target: nil, action: nil)
    private let pushBox = NSButton(checkboxWithTitle: "Push after committing", target: nil, action: nil)
    private let stageButton = NSButton(title: "Stage or Unstage", target: nil, action: nil)
    private let stageAllButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard Changes...", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private init(root: String, git: GitService, controller: MainWindowController) {
        self.root = root
        self.git = git
        self.controller = controller
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Commit in \((root as NSString).lastPathComponent)"
        window.basilAutosave("BasilCommitWindow")
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        buildContent()
        if !window.setFrameUsingName("BasilCommitWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.open[root] = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summary.setAccessibilityLabel("Repository")
        summary.setAccessibilityIdentifier("commit.summary")

        configure(changesTable, label: "Changes", identifier: "commit.changes", column: "Change")
        changesTable.allowsMultipleSelection = true
        configure(diffTable, label: "Diff", identifier: "commit.diff", column: "Line")
        diffNote.textColor = Theme.secondaryText
        diffNote.setAccessibilityIdentifier("commit.diffNote")

        let changesTitle = Self.title("Changes")
        let diffTitle = Self.title("Diff of the file under the cursor")
        let left = NSStackView(views: [changesTitle, scroll(changesTable)])
        left.orientation = .vertical
        left.alignment = .leading
        let right = NSStackView(views: [diffTitle, diffNote, scroll(diffTable)])
        right.orientation = .vertical
        right.alignment = .leading
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

        let messageTitle = Self.title("Message")
        messageView.isRichText = false
        messageView.font = Theme.listFont
        messageView.textColor = Theme.text
        messageView.backgroundColor = .textBackgroundColor
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.allowsUndo = true
        messageView.setAccessibilityLabel("Commit message")
        messageView.setAccessibilityIdentifier("commit.message")
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageView.autoresizingMask = [.width]
        messageView.isVerticallyResizable = true
        messageView.textContainer?.widthTracksTextView = true
        messageScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        amendBox.target = self
        amendBox.action = #selector(amendChanged)
        pushBox.target = self
        pushBox.action = #selector(pushChanged)
        pushBox.state = controller?.settings.settings.gitPushAfterCommit == true ? .on : .off
        stageButton.target = self
        stageButton.action = #selector(toggleStaged)
        stageButton.setAccessibilityHelp("Space in the list of changes")
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAll)
        discardButton.target = self
        discardButton.action = #selector(discard)
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.setAccessibilityHelp("Cmd+Return")
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.setAccessibilityHelp("Escape")

        let options = NSStackView(views: [amendBox, pushBox])
        options.orientation = .horizontal
        options.spacing = 16
        let buttons = NSStackView(views: [stageButton, stageAllButton, discardButton, NSView(), commitButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [summary, split, messageTitle, messageScroll, options, buttons])
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
            split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            messageScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.listBoldFont
        label.textColor = Theme.text
        // The tables carry the same name; the heading would be read twice.
        label.setAccessibilityElement(false)
        return label
    }

    private func configure(_ table: NSTableView, label: String, identifier: String, column title: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = Theme.rowHeight + 2
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.setAccessibilityLabel(label)
        table.setAccessibilityIdentifier(identifier)
        table.dataSource = self
        table.delegate = self
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    // MARK: Reading

    private var hasCommit: Bool { status.branch.commit != nil }

    /// Reads the repository's changes again; the cursor stays on the same file where it can.
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let git = git, root = root
        Task {
            do {
                let status = try await git.status(root: root, ignored: false, untrackedFiles: true)
                guard generation == loadGeneration else { return }
                apply(status)
            } catch {
                guard generation == loadGeneration else { return }
                summary.stringValue = "Could not read the changes: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ new: GitStatus) {
        let selectedPaths = Set(changesTable.selectedRowIndexes.compactMap { changes.indices.contains($0) ? changes[$0].path : nil })
        let cursorPath = changesTable.selectedRow >= 0 && changesTable.selectedRow < changes.count ? changes[changesTable.selectedRow].path : nil
        status = new
        changes = new.entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        summary.stringValue = summaryText()
        changesTable.reloadData()
        var rows = IndexSet(changes.indices.filter { selectedPaths.contains(changes[$0].path) })
        if rows.isEmpty, !changes.isEmpty {
            let cursor = cursorPath.flatMap { p in changes.firstIndex { $0.path >= p } } ?? 0
            rows = IndexSet(integer: min(cursor, changes.count - 1))
        }
        changesTable.selectRowIndexes(rows, byExtendingSelection: false)
        if changes.isEmpty { showDiff(nil) } else { loadDiff() }
        updateButtons()
    }

    private func summaryText() -> String {
        let branch = status.branch.head.map { "branch \($0)" } ?? "detached HEAD"
        var parts = ["\((root as NSString).lastPathComponent), \(branch)"]
        if let upstream = status.branch.upstream {
            if status.branch.ahead > 0 || status.branch.behind > 0 {
                parts.append("\(status.branch.ahead) ahead and \(status.branch.behind) behind \(upstream)")
            } else {
                parts.append("up to date with \(upstream)")
            }
        }
        if status.branch.commit == nil { parts.append("no commits yet") }
        let staged = changes.filter { $0.staging != .notStaged }.count
        parts.append(changes.isEmpty ? "no changes" : "\(count(changes.count, "change")), \(staged) staged")
        return parts.joined(separator: ", ")
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private func stagingText(_ entry: GitStatus.Entry) -> String {
        switch entry.staging {
        case .staged: "staged"
        case .notStaged: "not staged"
        case .partly: "partly staged"
        }
    }

    private func spoken(_ entry: GitStatus.Entry) -> String {
        var text = "\(entry.path), \(GitStatus.text(for: entry.change)), \(stagingText(entry))"
        if case .renamed(let from, _, _) = entry.change { text += ", from \(from)" }
        return text
    }

    private func loadDiff() {
        diffGeneration += 1
        let generation = diffGeneration
        let row = changesTable.selectedRow
        guard row >= 0, row < changes.count else { return showDiff(nil) }
        let entry = changes[row], git = git, root = root, hasCommit = hasCommit
        Task {
            let result: GitDiff
            do {
                result = try await git.diff(of: entry, root: root, hasCommit: hasCommit)
            } catch {
                result = GitDiff(lines: [], isBinary: false, note: "Could not read the diff: \(error.localizedDescription)")
            }
            guard generation == diffGeneration else { return }
            showDiff(result)
        }
    }

    private func showDiff(_ new: GitDiff?) {
        diff = new
        diffNote.stringValue = new?.note ?? (new == nil ? "No file" : "\(count(new!.lines.filter { $0.kind == .added || $0.kind == .removed }.count, "changed line"))")
        diffTable.reloadData()
    }

    private func updateButtons() {
        let any = !changes.isEmpty
        let selected = !changesTable.selectedRowIndexes.isEmpty
        stageButton.isEnabled = selected
        stageAllButton.isEnabled = changes.contains { $0.staging != .staged }
        discardButton.isEnabled = selected
        commitButton.isEnabled = any || amendBox.state == .on
        amendBox.isEnabled = hasCommit
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === changesTable ? changes.count : (diff?.lines.count ?? 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === changesTable {
            guard changes.indices.contains(row) else { return nil }
            let entry = changes[row]
            let id = NSUserInterfaceItemIdentifier("change")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
                ?? CompareRowCell(identifier: id, widths: [nil, 120, 104], flexibleFont: Theme.listFont)
            cell.show([entry.path, GitStatus.text(for: entry.change), stagingText(entry)], spoken: spoken(entry))
            return cell
        }
        guard let line = diff?.lines[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("diffLine")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: [64, 40, 40, nil],
                              flexibleFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        cell.show([line.kind.rawValue, line.oldLine.map(String.init) ?? "", line.newLine.map(String.init) ?? "",
                   line.kind == .hunk ? "" : line.text], spoken: GitDiff.spoken(line))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompareRowBackground()
        if tableView === diffTable, let line = diff?.lines[safe: row] {
            view.status = switch line.kind {
            case .added: .onlyRight
            case .removed: .onlyLeft
            case .hunk: .changed
            case .same, .note: .same
            }
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === changesTable else { return }
        loadDiff()
        updateButtons()
    }

    // MARK: Actions

    private var selectedEntries: [GitStatus.Entry] {
        changesTable.selectedRowIndexes.compactMap { changes.indices.contains($0) ? changes[$0] : nil }
    }

    /// Space: stages the selected rows, or unstages them when all are fully staged.
    @objc private func toggleStaged() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let unstage = entries.allSatisfy { $0.staging == .staged }
        let paths = entries.flatMap(\.paths)
        let what = entries.count == 1 ? (entries[0].path as NSString).lastPathComponent : count(entries.count, "file")
        let git = git, root = root, hasCommit = hasCommit
        Task {
            do {
                if unstage {
                    try await git.unstage(paths, root: root, hasCommit: hasCommit)
                } else {
                    try await git.stage(paths, root: root)
                }
                announce("\(unstage ? "Unstaged" : "Staged") \(what)")
                changed()
            } catch {
                announce("Could not \(unstage ? "unstage" : "stage") \(what): \(error.localizedDescription)")
            }
        }
    }

    @objc private func stageAll() {
        let paths = changes.filter { $0.staging != .staged }.flatMap(\.paths)
        guard !paths.isEmpty else { return }
        let git = git, root = root
        Task {
            do {
                try await git.stage(paths, root: root)
                announce("Staged all changes")
                changed()
            } catch {
                announce("Could not stage: \(error.localizedDescription)")
            }
        }
    }

    @objc private func discard() {
        let entries = selectedEntries
        guard !entries.isEmpty, let window, let controller else { return }
        let what = entries.count == 1 ? entries[0].path : count(entries.count, "file")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to \(what)?"
        let newFiles = entries.contains { entry in
            switch entry.change {
            case .untracked, .renamed: true
            case .changed(let index, _): index == "A" || !hasCommit
            default: false
            }
        }
        alert.informativeText = newFiles
            ? "Changed files go back to the last commit's version. New files are moved to the Trash."
            : "The files go back to the last commit's version. Your changes to them are lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        let root = root, hasCommit = hasCommit, git = git
        Task {
            guard await controller.present(alert, in: window) == 0 else { return }
            let item = controller.queue.add(DiscardChangesOperation(entries: entries, root: root, hasCommit: hasCommit,
                                                                    git: git, registry: controller.providers))
            item.whenDone = { [weak controller] _ in controller?.gitStateChanged() }
        }
    }

    @objc private func amendChanged() {
        updateButtons()
        guard amendBox.state == .on, messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let git = git, root = root
        Task {
            if let last = await git.lastCommitMessage(root: root), amendBox.state == .on, messageView.string.isEmpty {
                messageView.string = last
            }
        }
    }

    @objc private func pushChanged() {
        controller?.settings.settings.gitPushAfterCommit = pushBox.state == .on
    }

    @objc private func commit() {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let amend = amendBox.state == .on
        guard !message.isEmpty else {
            announce("Type a commit message first")
            window?.makeFirstResponder(messageView)
            return
        }
        guard amend || changes.contains(where: { $0.staging != .notStaged }) else {
            announce("Nothing is staged. Stage changes with Space first.")
            return
        }
        let git = git, root = root, push = pushBox.state == .on
        commitButton.isEnabled = false
        Task {
            defer { updateButtons() }
            do {
                try await git.commit(message: message, amend: amend, root: root)
                messageView.string = ""
                amendBox.state = .off
                let branch = status.branch.head.map { " to \($0)" } ?? ""
                announce(amend ? "Amended the last commit" : "Committed\(branch)")
                changed()
                if push { controller?.queueGitRemote(.push, root: root) }
            } catch {
                announce("Could not commit: \(error.localizedDescription)")
            }
        }
    }

    @objc private func closeWindow() { window?.close() }

    private func changed() {
        reload()
        controller?.left.refreshAnnotations(after: .zero)
        controller?.right.refreshAnnotations(after: .zero)
    }

    private func announce(_ message: String) {
        controller?.announce(message)
    }

    /// Keys anywhere in the window: Escape closes, Cmd+Return commits, Space in the list of
    /// changes stages or unstages.
    private func handle(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord(.escape), KeyChord(.character("w"), .command):
            closeWindow()
        case KeyChord(.enter, .command):
            commit()
        case KeyChord(.space) where window?.firstResponder === changesTable:
            toggleStaged()
        default:
            return false
        }
        return true
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
