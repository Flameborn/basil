import AppKit
import BasilCore
import BasilGit
import BasilOperations
import BasilVFS
import Synchronization

/// The Git commands (Commands > Git, and the context menu where they fit). No default keys
/// (user's decision, 2026-11-24); they are assigned in Settings > Keys like any command.
/// Registered only when git was found.
@MainActor
enum GitCommands {
    static func register(in registry: CommandRegistry, window: MainWindowController) {
        weak var w = window
        typealias C = CommandRegistry.Command
        let inRepository: @MainActor (any WorkspaceContext) -> Bool = { _ in w?.activePane.isInGitRepository ?? false }
        let onFile: @MainActor (any WorkspaceContext) -> Bool = { _ in
            guard let pane = w?.activePane, pane.isInGitRepository, let item = pane.cursorItem else { return false }
            return !item.isDirectoryLike
        }
        let commands = [
            C(id: "git.commit", title: "Commit...", isApplicable: inRepository) { _ in w?.openCommitWindow() },
            C(id: "git.branches", title: "Branches...", isApplicable: inRepository) { _ in w?.openBranchesWindow() },
            C(id: "git.log", title: "Log...", isApplicable: inRepository) { _ in w?.openLogWindow(forCursorFile: false) },
            C(id: "git.fileLog", title: "Log of File...", isApplicable: onFile) { _ in w?.openLogWindow(forCursorFile: true) },
            C(id: "git.blame", title: "Blame...", isApplicable: onFile) { _ in w?.openBlameWindow() },
            C(id: "git.pull", title: "Pull", isApplicable: inRepository) { _ in w?.queueGitRemote(.pull) },
            C(id: "git.push", title: "Push", isApplicable: inRepository) { _ in w?.queueGitRemote(.push) },
            C(id: "git.fetch", title: "Fetch", isApplicable: inRepository) { _ in w?.queueGitRemote(.fetch) },
        ]
        for command in commands { registry.register(command) }
        registry.menus.addToContextMenu([.separator, .submenu("Git", ["git.commit", "git.branches", "git.log", "git.fileLog", "git.blame", "git.pull", "git.push"].map(MenuNode.command))])
    }
}

extension PaneViewController {
    /// The Git annotator answered for the shown folder: it is inside a working tree.
    var isInGitRepository: Bool { gitAnnotation != nil }

    /// The branch of the repository holding the shown folder ("main", "detached HEAD").
    var gitBranch: String? { gitAnnotation?.details[GitAnnotator.branchDetail] }
}

extension MainWindowController {
    /// The working tree holding the active pane's folder, or nil with a spoken reason.
    func activeRepositoryRoot() async -> String? {
        guard let git else { return nil }
        guard let local = providers.localPath(of: activePane.model.directory) else {
            announce("Git works only in local folders and folders on mounted shares")
            return nil
        }
        guard let root = await git.repositoryRoot(of: local.path) else {
            announce("\(activePane.model.directory.name.isEmpty ? local.path : activePane.model.directory.name) is not in a Git repository")
            return nil
        }
        return root
    }

    /// Pull, push or fetch of the active pane's repository, as a queue item.
    func queueGitRemote(_ action: GitRemoteOperation.Action) {
        Task {
            guard let root = await activeRepositoryRoot() else { return }
            queueGitRemote(action, root: root)
        }
    }

    /// Queues the action. A push of a branch without an upstream asks to publish it first
    /// (to an existing remote, or to a new one by URL).
    func queueGitRemote(_ action: GitRemoteOperation.Action, root: String) {
        guard let git else { return }
        Task {
            var action = action
            if action == .push, let branch = await git.currentBranch(root: root), await git.upstream(root: root) == nil {
                guard let remote = await askPublish(branch: branch, root: root) else { return }
                action = .publish(branch: branch, remote: remote)
            }
            let item = queue.add(GitRemoteOperation(action, root: root, git: git,
                                                    login: GitLoginUI(controller: self, secrets: remoteSecrets)))
            item.whenDone = { [weak self] _ in self?.gitStateChanged() }
        }
    }

    /// "Publish main?": the remote to push to (a new one is added first). nil: cancelled.
    private func askPublish(branch: String, root: String) async -> String? {
        guard let git, let window else { return nil }
        let remotes = (try? await git.remotes(root: root)) ?? []
        let form = PublishForm(remotes: remotes)
        let alert = NSAlert()
        alert.messageText = "Publish \(branch)?"
        alert.informativeText = remotes.isEmpty
            ? "\(branch) has no upstream branch, and this repository has no remote yet. Add one: Basil pushes \(branch) there and tracks it."
            : "\(branch) has no upstream branch yet. Basil pushes it to the remote and tracks it there."
        alert.addButton(withTitle: "Publish")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form
        alert.window.initialFirstResponder = form.firstControl
        while true {
            let confirmed: Bool = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                alert.window.makeFirstResponder(form.firstControl)
            }
            guard confirmed else { return nil }
            guard form.addsRemote else { return form.chosenRemote }
            let name = form.nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let url = form.urlField.stringValue.trimmingCharacters(in: .whitespaces)
            var problem: String?
            if name.isEmpty || name.contains(where: \.isWhitespace) || name.hasPrefix("-") {
                problem = "Type a remote name without spaces, such as origin."
            } else if url.isEmpty {
                problem = "Type the remote's URL."
            } else if remotes.contains(name) {
                problem = "A remote named \(name) exists already."
            } else {
                do {
                    try await git.addRemote(name, url: url, root: root)
                    return name
                } catch {
                    problem = "Could not add the remote: \(error.localizedDescription)"
                }
            }
            // Asks again with the reason, keeping what was typed.
            alert.informativeText = problem ?? ""
            announce(problem ?? "")
        }
    }

    /// Git state changed (a commit, a pull): the panes ask the Git column again, open Git
    /// windows reread.
    func gitStateChanged() {
        left.refreshAnnotations(after: .zero)
        right.refreshAnnotations(after: .zero)
        CommitWindowController.refreshAll()
        BranchesWindowController.refreshAll()
    }

    func openBranchesWindow() {
        guard let git else { return }
        Task {
            guard let root = await activeRepositoryRoot() else { return }
            BranchesWindowController.show(root: root, git: git, controller: self)
        }
    }

    func openCommitWindow() {
        guard let git else { return }
        Task {
            guard let root = await activeRepositoryRoot() else { return }
            CommitWindowController.show(root: root, git: git, controller: self)
        }
    }
}

/// Logins git and ssh ask for while pulling, pushing or fetching (GIT_ASKPASS): Basil's own
/// sheets on the main window. A password remembered in the Keychain (key "git:" plus git's
/// prompt) is tried first; when git asks the same prompt again it was wrong, so it is
/// forgotten and the sheet asks. A new password is saved only once the git run worked.
final class GitLoginUI: GitLogin, @unchecked Sendable {
    private weak var controller: MainWindowController?
    private let secrets: any SecretStore
    /// Answers to remember once the run worked, by Keychain key.
    private let pending = Mutex<[String: String]>([:])

    @MainActor init(controller: MainWindowController, secrets: any SecretStore) {
        self.controller = controller
        self.secrets = secrets
    }

    func answer(_ prompt: GitPrompt, attempt: Int) async -> String? {
        let key = "git:" + prompt.text
        if prompt.kind == .secret {
            if attempt == 1, let stored = secrets.secret(for: key) { return stored }
            if attempt == 2, secrets.secret(for: key) != nil { secrets.remove(for: key) }
        }
        guard let controller = await MainActor.run(body: { controller }) else { return nil }
        switch prompt.kind {
        case .yesNo:
            return await controller.askGitQuestion(prompt.text) ? "yes" : "no"
        case .text:
            return await controller.askGitText(prompt.text)
        case .secret:
            let request = SecretRequest(kind: .serverPrompt(prompt.text), account: "Git", retry: attempt > 1, keychainKey: key)
            guard let answer = await controller.askSecret(request) else { return nil }
            if answer.remember { pending.withLock { $0[key] = answer.secret } }
            return answer.secret
        }
    }

    func finished(succeeded: Bool) async {
        let saved = pending.withLock { p in defer { p = [:] }; return p }
        guard succeeded else { return }
        for (key, secret) in saved { secrets.save(secret, for: key) }
    }
}

extension MainWindowController {
    /// ssh's yes/no questions (an unknown host key), with git's own text.
    func askGitQuestion(_ text: String) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = "Git asks a question"
        alert.informativeText = text
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return await present(alert, in: window) == 0
    }

    func askGitText(_ text: String) async -> String? {
        guard let window else { return nil }
        let label = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return await askText(in: window, message: text, initial: "", confirm: "OK", fieldLabel: label)
    }
}

/// The publish sheet's controls: the remote pop-up (existing remotes, then "New Remote"), and
/// the new remote's name and URL, used only for a new one.
final class PublishForm: NSView {
    static let newRemoteTitle = "New Remote"
    let popUp = NSPopUpButton()
    let nameField = NSTextField()
    let urlField = NSTextField()
    private let remotes: [String]

    init(remotes: [String]) {
        self.remotes = remotes
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: remotes.isEmpty ? 64 : 98))
        var y: CGFloat = 0
        func row(_ label: String, _ control: NSView) {
            let text = NSTextField(labelWithString: label + ":")
            // The control carries the same name.
            text.setAccessibilityElement(false)
            text.frame = NSRect(x: 0, y: y + 3, width: 70, height: 18)
            control.frame = NSRect(x: 76, y: y, width: 284, height: 24)
            control.setAccessibilityLabel(label)
            addSubview(text)
            addSubview(control)
            y += 34
        }
        urlField.placeholderString = "git@github.com:user/repo.git"
        row("URL", urlField)
        nameField.stringValue = remotes.isEmpty ? "origin" : ""
        row("Name", nameField)
        if !remotes.isEmpty {
            popUp.addItems(withTitles: remotes + [Self.newRemoteTitle])
            popUp.selectItem(withTitle: remotes.contains("origin") ? "origin" : remotes[0])
            popUp.target = self
            popUp.action = #selector(remoteChanged)
            row("Remote", popUp)
        }
        remoteChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var addsRemote: Bool { remotes.isEmpty || popUp.titleOfSelectedItem == Self.newRemoteTitle }
    var chosenRemote: String? { popUp.titleOfSelectedItem }
    var firstControl: NSView { remotes.isEmpty ? urlField : popUp }

    @objc private func remoteChanged() {
        nameField.isEnabled = addsRemote
        urlField.isEnabled = addsRemote
    }
}
