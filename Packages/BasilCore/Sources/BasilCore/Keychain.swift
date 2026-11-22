import Foundation
import Security
import Synchronization

/// Somewhere to keep secrets by key. `Keychain` is the real one; tests use their own.
public protocol SecretStore: Sendable {
    func secret(for key: String) -> String?
    func save(_ secret: String, for key: String)
    func remove(for key: String)
}

/// Generic passwords in the user's login keychain, under one service name.
/// Credentials and archive passwords live only here (never in settings files).
public struct Keychain: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    /// Archive passwords, found by the archive's path.
    public static let archivePasswords = Keychain(service: "com.flameborn.basil.archive-password")
    /// Server passwords ("sftp:user@host:port") and private key passphrases ("ssh-key:/path").
    public static let remoteSecrets = Keychain(service: "com.flameborn.basil.remote-secret")

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func secret(for key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ secret: String, for key: String) {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Basil: \(key)"
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    public func remove(for key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// Secrets kept in memory only: for UI tests and package tests, which must not touch the
/// user's keychain.
public final class MemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: String]>([:])
    public init() {}
    public func secret(for key: String) -> String? { secrets.withLock { $0[key] } }
    public func save(_ secret: String, for key: String) { secrets.withLock { $0[key] = secret } }
    public func remove(for key: String) { secrets.withLock { _ = $0.removeValue(forKey: key) } }
}
