import BasilCore
import Foundation
import Synchronization

/// A question about a server's host key that only the user can answer.
public struct HostKeyQuestion: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The host is not in known_hosts.
        case unknown
        /// known_hosts has a different key of the same type: possibly an attack.
        case changed
    }

    public var reason: Reason
    /// "example.com" or "[example.com]:2222", as known_hosts writes it.
    public var host: String
    /// "ED25519", "ECDSA", "RSA".
    public var keyType: String
    /// "SHA256:..." like ssh prints it.
    public var fingerprint: String
    /// Where the key would be saved.
    public var knownHostsFile: String

    public init(reason: Reason, host: String, keyType: String, fingerprint: String, knownHostsFile: String) {
        self.reason = reason
        self.host = host
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.knownHostsFile = knownHostsFile
    }
}

public enum HostKeyAnswer: Sendable, Equatable {
    /// Connect and save the key in known_hosts (replacing a changed one).
    case trustAndRemember
    /// Connect this time only.
    case trustOnce
    case cancel
}

/// A secret a connection needs: a password, a key passphrase or a keyboard-interactive answer.
public struct SecretRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case password
        /// The path of the encrypted private key.
        case passphrase(keyFile: String)
        /// A server question (keyboard-interactive), with its own prompt text.
        case serverPrompt(String)
    }

    public var kind: Kind
    /// "user@host" or "user@host:port".
    public var account: String
    /// The previous answer was wrong.
    public var retry: Bool
    /// Keychain key the UI may read before asking and save to after it worked.
    public var keychainKey: String?

    public init(kind: Kind, account: String, retry: Bool, keychainKey: String?) {
        self.kind = kind
        self.account = account
        self.retry = retry
        self.keychainKey = keychainKey
    }
}

public struct SecretAnswer: Sendable, Equatable {
    public var secret: String
    /// Save in the Keychain once it worked.
    public var remember: Bool
    public init(secret: String, remember: Bool) {
        self.secret = secret
        self.remember = remember
    }
}

/// The UI's side of connecting: questions only the user can answer. Every call may wait for the
/// user; nil or `.cancel` stops the connection.
public protocol RemotePrompts: Sendable {
    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer
    func secret(_ request: SecretRequest) async -> SecretAnswer?
    /// A secret worked: save it if the user asked to.
    func secretWorked(_ request: SecretRequest, _ answer: SecretAnswer) async
    /// Something the user should know about the connection (unsupported ssh config keys, ...).
    func note(_ message: String) async
}

extension RemotePrompts {
    public func secretWorked(_ request: SecretRequest, _ answer: SecretAnswer) async {}
    public func note(_ message: String) async {}
}

/// The connection was stopped by the user (a cancelled prompt).
public struct RemoteCancelled: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Connection cancelled" }
}

/// A remote service (SFTP now; FTP, Dropbox and others later, also from plugins). Registered in
/// `ProviderRegistry`; the UI only asks the registry.
public protocol RemoteConnector: Sendable {
    var service: ProviderID { get }
    /// "SFTP"
    var displayName: String { get }
    var defaultPort: Int { get }
    /// Host aliases the service knows on its own (SFTP: ~/.ssh/config), for suggestions.
    func knownHosts() -> [String]
    /// Opens a connection. The provider's location identifies it (same server and user: same
    /// location); `start` is the folder to show first.
    func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath)
}

extension RemoteConnector {
    public func knownHosts() -> [String] { [] }
}

/// A provider that holds a connection. Disconnect closes it.
public protocol ConnectedProvider: FileSystemProvider {
    /// "erion@example.com", for menus and the path bar.
    var connectionTitle: String { get }
    /// The folder the server starts in (the user's home there).
    var homeDirectory: VFSPath { get }
    func disconnect() async
}

extension ProviderRegistry {
    public func register(connector: any RemoteConnector) {
        connectors.withLock { list in
            list.removeAll { $0.service == connector.service }
            list.append(connector)
        }
    }

    public var remoteConnectors: [any RemoteConnector] { connectors.withLock { $0 } }

    public func connector(for service: ProviderID) -> (any RemoteConnector)? {
        connectors.withLock { list in list.first { $0.service == service } }
    }

    /// Connects (or reuses an open connection to the same location) and returns the start folder.
    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws -> VFSPath {
        guard let connector = connector(for: target.service) else {
            throw VFSError.unsupported("connecting with \(target.service)")
        }
        let (provider, start) = try await connector.connect(target, prompts: prompts)
        if let open = try? self.provider(for: provider.location), open is any ConnectedProvider {
            // Already connected: keep the open connection, drop the new one.
            if let fresh = provider as? any ConnectedProvider { await fresh.disconnect() }
            return VFSPath(location: open.location, path: start.path)
        }
        register(provider)
        return start
    }

    /// The open connections, in no particular order.
    public var openConnections: [any ConnectedProvider] {
        allProviders().compactMap { $0 as? any ConnectedProvider }
    }

    /// Closes a connection and every container opened inside it.
    public func disconnect(_ location: ProviderLocation) async {
        let provider = try? provider(for: location)
        _ = removeProviders { candidate in
            var current: ProviderLocation? = candidate
            while let c = current {
                if c == location { return true }
                current = c.container?.location
            }
            return false
        }
        if let connected = provider as? any ConnectedProvider { await connected.disconnect() }
    }
}
