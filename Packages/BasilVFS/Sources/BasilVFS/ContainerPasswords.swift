import BasilCore
import Foundation
import Synchronization

/// Asks for and remembers passwords of encrypted containers (archives). The UI installs one in
/// `ProviderRegistry.passwords`; without one, encrypted containers fail with a clear error.
public protocol ContainerPasswords: Sendable {
    /// A password for `container`. `retry` is true when the last one given was wrong.
    /// nil means the user cancelled.
    func password(for container: VFSPath, retry: Bool) async -> String?
    /// The password worked: keep it while the app runs, and in the Keychain if the user asked.
    func accepted(_ password: String, for container: VFSPath)
}

/// Passwords kept in memory while the app runs, read from and (when the user ticks "Remember
/// in Keychain") saved to a `SecretStore`, found by the container's path; otherwise asks.
public final class RememberingPasswords: ContainerPasswords {
    public struct Answer: Sendable {
        public var password: String
        public var remember: Bool
        public init(password: String, remember: Bool) {
            self.password = password
            self.remember = remember
        }
    }

    /// Shows the prompt. `retry`: the last password was wrong. nil: cancelled.
    public typealias Prompt = @Sendable (_ container: VFSPath, _ retry: Bool) async -> Answer?

    private let store: any SecretStore
    private let prompt: Prompt
    private let state = Mutex<(memory: [VFSPath: String], remember: [VFSPath: Bool])>(([:], [:]))

    public init(store: any SecretStore, prompt: @escaping Prompt) {
        self.store = store
        self.prompt = prompt
    }

    /// The Keychain key: the archive's path, with the containers it is in ("/a/outer.zip > /inner.7z").
    public static func key(for container: VFSPath) -> String {
        var parts = [container.path]
        var location = container.location
        while let outer = location.container {
            parts.insert(outer.path, at: 0)
            location = outer.location
        }
        return parts.joined(separator: " > ")
    }

    public func password(for container: VFSPath, retry: Bool) async -> String? {
        if retry {
            state.withLock { _ = $0.memory.removeValue(forKey: container) }
        } else {
            if let known = state.withLock({ $0.memory[container] }) { return known }
            if let saved = store.secret(for: Self.key(for: container)) { return saved }
        }
        guard let answer = await prompt(container, retry) else { return nil }
        state.withLock { $0.remember[container] = answer.remember }
        return answer.password
    }

    public func accepted(_ password: String, for container: VFSPath) {
        let remember = state.withLock { s -> Bool in
            s.memory[container] = password
            return s.remember.removeValue(forKey: container) ?? false
        }
        if remember { store.save(password, for: Self.key(for: container)) }
    }
}
