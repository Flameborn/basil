import AppKit
import BasilCore
import BasilVFS

extension MainWindowController {
    /// Installs the archive password source: memory, then the Keychain (`secrets`), then this prompt.
    func installPasswordPrompt(secrets: any SecretStore) {
        providers.passwords = RememberingPasswords(store: secrets) { [weak self] container, retry in
            await self?.askArchivePassword(for: container, retry: retry)
        }
    }

    /// A sheet asking for an archive's password, with "Remember in Keychain" (off).
    func askArchivePassword(for container: VFSPath, retry: Bool) async -> RememberingPasswords.Answer? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = retry ? "Wrong password for \(container.name). Try again." : "Password for \(container.name):"
        alert.informativeText = retry ? "Type the password again." : "The archive is encrypted."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 300
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: width, height: 24))
        field.setAccessibilityLabel("Password")
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        remember.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        [field, remember].forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        let confirmed: Bool = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            alert.window.makeFirstResponder(field)
        }
        guard confirmed else { return nil }
        return RememberingPasswords.Answer(password: field.stringValue, remember: remember.state == .on)
    }
}
