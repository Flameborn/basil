import AppKit
import BasilCore
import BasilGit
import BasilOperations

/// A read-only list of lines in a window of its own: a file's diff in a commit, a blame. Every
/// row reads as one sentence; F8 and Shift+F8 jump to the next and previous marked row (the
/// changed lines of a diff) and speak it; Escape closes.
@MainActor
final class GitLinesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var cells: [String]
        var spoken: String
        var background: CompareStatus = .same
        var isMarked = false
    }

    private static var openWindows: Set<GitLinesWindowController> = []

    private let rows: [Row]
    private let widths: [CGFloat?]
    private let announce: (String) -> Void
    private let summary: NSTextField
    fileprivate let table = CompareTableView()

    init(title: String, summary text: String, rows: [Row], widths: [CGFloat?], identifier: String,
         announce: @escaping (String) -> Void) {
        self.rows = rows
        self.widths = widths
        self.announce = announce
        summary = NSTextField(wrappingLabelWithString: text)
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = title
        window.basilAutosave("BasilGitLinesWindow")
        window.contentMinSize = NSSize(width: 600, height: 300)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        build(identifier: identifier)
        if !window.setFrameUsingName("BasilGitLinesWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        Self.openWindows.insert(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
        let first = rows.firstIndex(where: \.isMarked) ?? 0
        if !rows.isEmpty { select(first, speak: false) }
        announce(summary.stringValue)
    }

    func windowWillClose(_ notification: Notification) { Self.openWindows.remove(self) }

    private func build(identifier: String) {
        guard let content = window?.contentView else { return }
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summary.setAccessibilityLabel("Summary")
        summary.setAccessibilityIdentifier("\(identifier).summary")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Line"))
        column.title = "Line"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = Theme.rowHeight + 2
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Lines")
        table.setAccessibilityIdentifier("\(identifier).table")
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.setAccessibilityHelp("Escape")
        let stack = NSStackView(views: [summary, scroll, close])
        stack.orientation = .vertical
        stack.alignment = .trailing
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
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let line = rows[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("gitLine")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: widths, flexibleFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
        cell.show(line.cells, spoken: line.spoken)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompareRowBackground()
        view.status = rows[safe: row]?.background ?? .same
        return view
    }

    private func select(_ row: Int, speak: Bool) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if speak { announce(rows[row].spoken) }
    }

    private func jump(forward: Bool) {
        let current = table.selectedRow
        let marked = rows.indices.filter { rows[$0].isMarked }
        let target = forward ? marked.first { $0 > current } : marked.last { $0 < current }
        if let target { select(target, speak: true) } else { announce(marked.isEmpty ? "No changes" : "No more changes") }
    }

    @objc private func closeWindow() { window?.close() }

    private func handle(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord(.escape), KeyChord(.character("w"), .command): closeWindow()
        case KeyChord(.function(8)): jump(forward: true)
        case KeyChord(.function(8), .shift): jump(forward: false)
        default: return false
        }
        return true
    }

    /// Rows for a diff: kind, old and new line numbers, text; changed lines are marked.
    static func rows(for diff: GitDiff) -> [Row] {
        diff.lines.map { line in
            Row(cells: [line.kind.rawValue, line.oldLine.map(String.init) ?? "", line.newLine.map(String.init) ?? "",
                        line.kind == .hunk ? "" : line.text],
                spoken: GitDiff.spoken(line),
                background: line.kind == .added ? .onlyRight : line.kind == .removed ? .onlyLeft : line.kind == .hunk ? .changed : .same,
                isMarked: line.kind == .hunk)
        }
    }
}

/// Commands > Git > Log... (the branch's commits) and Log of File... (one file's history):
/// commits newest first ("a1b2c3d, Fix the parser, Flameborn, 2 days ago"), the selected
/// commit's message and changed files ("Modified, src/main.swift"); Return on a file opens its
/// diff in that commit.
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var openWindows: Set<LogWindowController> = []

    private let root: String
    private let path: String?
    private let git: GitService
    private weak var controller: MainWindowController?
    private var commits: [GitCommit] = []
    private var files: [GitCommitFile] = []
    private var filesGeneration = 0
    private let limit = 1000
    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private let summary = NSTextField(wrappingLabelWithString: "Reading the log")
    fileprivate let commitsTable = CompareTableView()
    private let filesTable = CompareTableView()
    private let messageView = NSTextView()

    init(root: String, path: String?, git: GitService, controller: MainWindowController) {
        self.root = root
        self.path = path
        self.git = git
        self.controller = controller
        let window = CompareNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Log of \(((path ?? root) as NSString).lastPathComponent)"
        window.basilAutosave("BasilLogWindow")
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] chord in self?.handle(chord) ?? false }
        build()
        if !window.setFrameUsingName("BasilLogWindow") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        Self.openWindows.insert(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(commitsTable)
        load()
    }

    func windowWillClose(_ notification: Notification) { Self.openWindows.remove(self) }

    private func build() {
        guard let content = window?.contentView else { return }
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summary.setAccessibilityLabel("Summary")
        summary.setAccessibilityIdentifier("log.summary")
        configure(commitsTable, label: "Commits", identifier: "log.commits")
        configure(filesTable, label: "Changed files", identifier: "log.files")
        filesTable.doubleAction = #selector(openFileDiff)
        filesTable.target = self

        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.font = Theme.listFont
        messageView.textColor = Theme.text
        messageView.backgroundColor = .textBackgroundColor
        messageView.setAccessibilityLabel("Commit message")
        messageView.setAccessibilityIdentifier("log.message")
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true

        let details = NSSplitView()
        details.isVertical = true
        details.dividerStyle = .thin
        details.addArrangedSubview(messageScroll)
        details.addArrangedSubview(scroll(filesTable))
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        let commitsScroll = scroll(commitsTable)
        split.addArrangedSubview(commitsScroll)
        split.addArrangedSubview(details)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        commitsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let openButton = NSButton(title: "Show Diff", target: self, action: #selector(openFileDiff))
        openButton.setAccessibilityHelp("Return in the list of changed files")
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.setAccessibilityHelp("Escape")
        let buttons = NSStackView(views: [openButton, NSView(), close])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [summary, split, buttons])
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
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            details.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            messageScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func configure(_ table: NSTableView, label: String, identifier: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(label.replacingOccurrences(of: " ", with: "")))
        column.title = label
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

    private func load() {
        let git = git, root = root, path = path, limit = limit
        Task {
            do {
                commits = try await git.log(root: root, path: path, limit: limit)
                let what = path ?? (root as NSString).lastPathComponent
                var text = commits.isEmpty ? "\(what): no commits" : "\(what): \(commits.count) commit\(commits.count == 1 ? "" : "s")"
                if commits.count == limit { text += ", the newest \(limit) are shown" }
                summary.stringValue = text
                commitsTable.reloadData()
                if !commits.isEmpty { commitsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                controller?.announce(text)
            } catch {
                summary.stringValue = "Could not read the log: \(error.localizedDescription)"
                controller?.announce(summary.stringValue)
            }
        }
    }

    private var selectedCommit: GitCommit? { commits[safe: commitsTable.selectedRow] }

    private func loadFiles() {
        filesGeneration += 1
        let generation = filesGeneration
        guard let commit = selectedCommit else {
            files = []
            filesTable.reloadData()
            messageView.string = ""
            return
        }
        messageView.string = "\(commit.message)\n\n\(commit.author) <\(commit.email)>, \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.hash)"
        let git = git, root = root
        Task {
            let new = (try? await git.files(of: commit, root: root)) ?? []
            guard generation == filesGeneration else { return }
            files = new
            filesTable.reloadData()
            if !files.isEmpty { filesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
    }

    private func commitCells(_ commit: GitCommit) -> [String] {
        [commit.shortHash, commit.subject, commit.author, relative.localizedString(for: commit.date, relativeTo: Date())]
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === commitsTable ? commits.count : files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === commitsTable {
            guard let commit = commits[safe: row] else { return nil }
            let id = NSUserInterfaceItemIdentifier("commit")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
                ?? CompareRowCell(identifier: id, widths: [80, nil, 180, 140], flexibleFont: Theme.listFont)
            let cells = commitCells(commit)
            cell.show(cells, spoken: cells.joined(separator: ", "))
            return cell
        }
        guard let file = files[safe: row] else { return nil }
        let id = NSUserInterfaceItemIdentifier("commitFile")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompareRowCell
            ?? CompareRowCell(identifier: id, widths: [120, nil], flexibleFont: Theme.listFont)
        let status: String = switch file.change {
        case .renamed: "Renamed"
        case .copied: "Copied"
        default: file.text
        }
        cell.show([status, file.path], spoken: "\(file.text), \(file.path)")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CompareRowBackground() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === commitsTable else { return }
        loadFiles()
    }

    @objc private func openFileDiff() {
        guard let commit = selectedCommit, let file = files[safe: filesTable.selectedRow], let controller else { return }
        let git = git, root = root
        weak var announcer = controller
        Task {
            do {
                let diff = try await git.diff(of: file, in: commit, root: root)
                let changed = diff.lines.filter { $0.kind == .added || $0.kind == .removed }.count
                let text = diff.note ?? "\(file.path) in \(commit.shortHash) \(commit.subject): \(changed) changed line\(changed == 1 ? "" : "s")"
                GitLinesWindowController(title: "\((file.path as NSString).lastPathComponent) in \(commit.shortHash)",
                                         summary: text, rows: GitLinesWindowController.rows(for: diff),
                                         widths: [64, 40, 40, nil], identifier: "diff",
                                         announce: { announcer?.announce($0) }).show()
            } catch {
                controller.announce("Could not show the diff: \(error.localizedDescription)")
            }
        }
    }

    @objc private func closeWindow() { window?.close() }

    private func handle(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord(.escape), KeyChord(.character("w"), .command): closeWindow()
        case KeyChord(.enter) where window?.firstResponder === filesTable: openFileDiff()
        default: return false
        }
        return true
    }
}

extension MainWindowController {
    /// The cursor item's path inside the repository holding it, when it is a file.
    func cursorFileInRepository() async -> (root: String, path: String)? {
        guard let item = activePane.cursorItem, !item.isDirectoryLike else {
            announce("Put the cursor on a file")
            return nil
        }
        guard let root = await activeRepositoryRoot(), let local = providers.localPath(of: item.path),
              let relative = GitService.relative(local.path, to: root) else { return nil }
        return (root, relative)
    }

    func openLogWindow(forCursorFile: Bool) {
        guard let git else { return }
        Task {
            if forCursorFile {
                guard let file = await cursorFileInRepository() else { return }
                LogWindowController(root: file.root, path: file.path, git: git, controller: self).show()
            } else {
                guard let root = await activeRepositoryRoot() else { return }
                LogWindowController(root: root, path: nil, git: git, controller: self).show()
            }
        }
    }

    /// Blame of the cursor file: "Flameborn, 3 days ago, line 12: let x = 2" (author first,
    /// user's choice); lines not committed yet say so.
    func openBlameWindow() {
        guard let git else { return }
        weak var announcer = self
        Task {
            guard let file = await cursorFileInRepository() else { return }
            do {
                let lines = try await git.blame(file.path, root: file.root)
                let relative = RelativeDateTimeFormatter()
                relative.unitsStyle = .full
                let rows = lines.map { line -> GitLinesWindowController.Row in
                    let when = line.date.map { relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
                    let content = line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : line.text
                    let spoken = ([line.author, when].filter { !$0.isEmpty } + ["line \(line.line): \(content)"]).joined(separator: ", ")
                    return GitLinesWindowController.Row(cells: [line.author, when, line.isUncommitted ? "" : line.shortHash,
                                                                String(line.line), line.text],
                                                        spoken: spoken, background: line.isUncommitted ? .changed : .same,
                                                        isMarked: line.isUncommitted)
                }
                let authors = Set(lines.filter { !$0.isUncommitted }.map(\.author)).count
                let uncommitted = lines.filter(\.isUncommitted).count
                var summary = "\(file.path): \(lines.count) line\(lines.count == 1 ? "" : "s") by \(authors) author\(authors == 1 ? "" : "s")"
                if uncommitted > 0 { summary += ", \(uncommitted) not committed yet" }
                GitLinesWindowController(title: "Blame of \((file.path as NSString).lastPathComponent)", summary: summary,
                                         rows: rows, widths: [150, 120, 70, 44, nil], identifier: "blame",
                                         announce: { announcer?.announce($0) }).show()
            } catch {
                announce("Could not blame \((file.path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
