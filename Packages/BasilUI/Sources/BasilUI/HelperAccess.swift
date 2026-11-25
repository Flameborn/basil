import AppKit
import BasilCore
import BasilOperations
import BasilVFS
import ServiceManagement

/// Copies and moves as an administrator through BasilHelper, the launchd daemon in
/// Contents/Library/LaunchDaemons (SMAppService). The first time, macOS has to allow it: Basil
/// registers it, then asks the user to turn it on in System Settings > General > Login Items and
/// Extensions (macOS asks for an administrator password there) and waits until it is on. Each
/// operation then connects, the helper shows macOS's password dialog, and
/// `PrivilegedLocalProvider` is registered until the operation ends.
final class HelperAccess: AdministratorFiles, @unchecked Sendable {
    /// How long the password is remembered after an operation, like sudo.
    static let remembered: Duration = .seconds(300)

    private let registry: ProviderRegistry
    @MainActor private weak var controller: MainWindowController?
    /// The authorized connection, kept for `remembered` after the last operation ended.
    @MainActor private var client: PrivilegedXPCClient?
    @MainActor private var provider: PrivilegedLocalProvider?
    @MainActor private var forget: Task<Void, Never>?

    @MainActor init(registry: ProviderRegistry, controller: MainWindowController) {
        self.registry = registry
        self.controller = controller
    }

    static var service: SMAppService { SMAppService.daemon(plistName: BasilHelper.plistName) }

    /// Not allowed in System Settings (the user cancelled): callers fall back where they can.
    struct NotAllowed: LocalizedError {
        var errorDescription: String? { "Basil's administrator helper is not allowed in System Settings" }
    }

    func begin(prompt: String) async throws {
        if let kept = await keptProvider(), (try? await kept.item(at: VFSPath(location: .localAdministrator, path: "/"))) != nil {
            registry.register(kept)
            return
        }
        await forgetNow()
        try await enableHelper()
        guard let client = PrivilegedXPCClient() else {
            throw VFSError.failed("Basil is not signed with a certificate, so its administrator helper cannot check it")
        }
        let provider = PrivilegedLocalProvider(transport: client)
        do {
            try await provider.authorize(authorization: client.externalAuthorization, prompt: prompt)
        } catch {
            await client.close()
            throw error
        }
        registry.register(provider)
        await MainActor.run {
            self.client = client
            self.provider = provider
        }
    }

    /// Keeps the connection (and so the password) for `remembered`, then closes it.
    func end() async {
        await MainActor.run {
            forget?.cancel()
            forget = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.remembered)
                guard !Task.isCancelled else { return }
                await self?.forgetNow()
            }
        }
    }

    @MainActor private func keptProvider() -> PrivilegedLocalProvider? {
        forget?.cancel()
        forget = nil
        return provider
    }

    @MainActor private func forgetNow() async {
        registry.unregister(.localAdministrator)
        let old = client
        client = nil
        provider = nil
        await old?.close()
    }

    /// Registers the helper and waits until macOS allows it. Throws `PrivilegedAccessDeclined`
    /// when the user cancels.
    @MainActor private func enableHelper() async throws {
        let service = Self.service
        if service.status == .enabled { return }
        if service.status != .requiresApproval {
            // Throws "Operation not permitted" until the user allows it; the status says so.
            do { try service.register() } catch where service.status == .requiresApproval {}
            if service.status == .enabled { return }
        }
        guard service.status == .requiresApproval else {
            throw VFSError.failed("macOS did not accept Basil's administrator helper (status \(service.status.rawValue))")
        }
        guard let controller, try await controller.askToAllowHelper() else { throw NotAllowed() }
    }

    /// Settings > Copying: whether the helper is allowed, and removing it.
    @MainActor static var statusText: String {
        switch service.status {
        case .enabled: "Allowed"
        case .requiresApproval: "Waiting to be allowed in System Settings"
        case .notRegistered: "Not installed"
        case .notFound: "Not found in Basil"
        @unknown default: "Unknown"
        }
    }
}

extension MainWindowController {
    /// The window an operation's sheet goes on: the progress window while it is open.
    var operationSheetWindow: NSWindow? {
        progressWindow.isOpen ? progressWindow.window : window
    }

    /// Asks the user to allow the helper in System Settings and waits until it is allowed.
    /// False when cancelled.
    func askToAllowHelper() async throws -> Bool {
        guard let window = operationSheetWindow else { return false }
        let ask = NSAlert()
        ask.messageText = "Allow Basil's administrator helper"
        ask.informativeText = """
        To copy and move items that need an administrator, Basil uses a helper that macOS runs for it. \
        Turn on Basil under Allow in the Background in System Settings, General, Login Items and Extensions. \
        macOS asks for an administrator password there. You can turn it off again at any time.
        """
        ask.addButton(withTitle: "Open System Settings")
        ask.addButton(withTitle: "Cancel")
        guard await present(ask, in: window) == 0 else { return false }
        SMAppService.openSystemSettingsLoginItems()

        let wait = NSAlert()
        wait.messageText = "Waiting for the helper to be allowed"
        wait.informativeText = "Turn on Basil under Allow in the Background in System Settings. Basil goes on by itself once it is on."
        wait.addButton(withTitle: "Cancel")
        wait.addButton(withTitle: "Open System Settings Again")
        nonisolated(unsafe) let sheet = wait.window
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if HelperAccess.service.status == .enabled {
                    if sheet.sheetParent != nil { window.endSheet(sheet, returnCode: .OK) }
                    NSApp.activate()
                    return
                }
            }
        }
        defer { poll.cancel() }
        while true {
            let answer = await present(wait, in: window)
            if HelperAccess.service.status == .enabled {
                announce("Helper allowed")
                return true
            }
            guard answer == 1 else { return false }
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
