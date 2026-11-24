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
        let commands = [
            C(id: "git.commit", title: "Commit...", isApplicable: inRepository) { _ in w?.openCommitWindow() },
            C(id: "git.branches", title: "Branches...", isApplicable: inRepository) { _ in w?.openBranchesWindow() },
            C(id: "git.pull", title: "Pull", isApplicable: inRepository) { _ in w?.queueGitRemote(.pull) },
            C(id: "git.push", title: "Push", isApplicable: inRepository) { _ in w?.queueGitRemote(.push) },
            C(id: "git.fetch", title: "Fetch", isApplicable: inRepository) { _ in w?.queueGitRemote(.fetch) },
        ]
        for command in commands { registry.register(command) }
        registry.menus.addToContextMenu([.separator, .submenu("Git", ["git.commit", "git.branches", "git.pull", "git.push"].map(MenuNode.command))])
    }
}

extension PaneViewController {
    /// The Git annotator answered for the shown folder: it is inside a working tree.
    var isInGitRepository: Bool { gitAnnotation != nil }
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

    func queueGitRemote(_ action: GitRemoteOperation.Action, root: String) {
        guard let git else { return }
        let item = queue.add(GitRemoteOperation(action, root: root, git: git, login: GitLoginUI(controller: self, secrets: remoteSecrets)))
        item.whenDone = { [weak self] _ in self?.gitStateChanged() }
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
