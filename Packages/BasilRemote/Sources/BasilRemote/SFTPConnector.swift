import BasilCore
import BasilVFS
import CLibSSH2
import Foundation

/// Connects to SFTP servers. Host names go through ~/.ssh/config first (HostName, User, Port,
/// IdentityFile, IdentitiesOnly), host keys are checked against ~/.ssh/known_hosts, and the login
/// follows ssh's order: ssh-agent, key files (asking for passphrases), then password or
/// keyboard-interactive.
public struct SFTPConnector: RemoteConnector {
    public var service: ProviderID { .sftp }
    public var displayName: String { "SFTP" }
    public var defaultPort: Int { 22 }

    /// Where ~/.ssh lives and which agent socket to use (tests use their own).
    let home: URL
    let knownHostsFile: URL
    let agentSocket: String?
    let defaultKeys: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                knownHostsFile: URL? = nil, agentSocket: String? = nil, defaultKeys: Bool = true) {
        self.home = home
        self.knownHostsFile = knownHostsFile ?? home.appendingPathComponent(".ssh/known_hosts")
        self.agentSocket = agentSocket
        self.defaultKeys = defaultKeys
    }

    public func knownHosts() -> [String] { SSHConfig.user(home: home).aliases }

    func endpoint(for target: RemoteTarget) -> (SSHEndpoint, unsupported: [String]) {
        let config = SSHConfig.user(home: home).resolve(target.host, home: home.path)
        let identities: [String] = switch target.authentication {
        case .keyFile(let path): [path.hasPrefix("~/") ? home.path + path.dropFirst() : path]
        default: config.identityFiles.filter { FileManager.default.fileExists(atPath: $0) }
        }
        let endpoint = SSHEndpoint(
            alias: target.host,
            host: config.hostName ?? target.host,
            port: target.port ?? config.port ?? 22,
            user: target.user ?? config.user ?? NSUserName(),
            identityFiles: identities,
            identitiesOnly: config.identitiesOnly ?? false,
            authentication: target.authentication,
            agentSocket: agentSocket
        )
        return (endpoint, config.unsupported)
    }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let (endpoint, unsupported) = endpoint(for: target)
        if !unsupported.isEmpty {
            await prompts.note("Basil ignores these ~/.ssh/config settings for \(target.host): \(unsupported.joined(separator: "; "))")
        }
        let connection = SSHConnection(endpoint: endpoint)
        do {
            let key = try await connection.run { try connection.open() }
            try await checkHostKey(key, endpoint: endpoint, prompts: prompts)
            let login = try await logIn(connection, prompts: prompts)
            let home = try await connection.run {
                try connection.finish(hostKey: key, login: login)
                return try Self.realPath(connection, ".")
            }
            let provider = SFTPProvider(connection: connection, home: home)
            var startPath = home
            if let path = target.path, !path.isEmpty {
                startPath = path.hasPrefix("/") ? path : home + "/" + path
            }
            let start = VFSPath(location: provider.location, path: startPath)
            return (provider, start)
        } catch {
            _ = try? await connection.run { connection.close() }
            throw error
        }
    }

    // MARK: Host key

    func checkHostKey(_ key: Data, endpoint: SSHEndpoint, prompts: any RemotePrompts) async throws {
        var known = KnownHosts(file: knownHostsFile)
        let name = endpoint.knownHostsName
        let result = known.check(host: name, key: key)
        if result == .known { return }
        if result == .revoked {
            throw VFSError.failed("The host key of \(endpoint.host) is marked as revoked in \(knownHostsFile.path)")
        }
        let question = HostKeyQuestion(reason: result == .changed ? .changed : .unknown, host: name,
                                       keyType: KnownHosts.displayType(of: key),
                                       fingerprint: KnownHosts.fingerprint(of: key),
                                       knownHostsFile: knownHostsFile.path)
        switch await prompts.hostKey(question) {
        case .cancel: throw RemoteCancelled()
        case .trustOnce: return
        case .trustAndRemember:
            do { try known.remember(host: name, key: key) } catch {
                await prompts.note("Could not save the host key in \(knownHostsFile.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Login

    func logIn(_ connection: SSHConnection, prompts: any RemotePrompts) async throws -> SSHLogin {
        let endpoint = connection.endpoint
        let methods = try await connection.run { try connection.authMethods() }
        if methods.isEmpty { return .none }
        let auth = endpoint.authentication
        let allowKeys = methods.contains("publickey")

        if allowKeys, case .automatic = auth, !endpoint.identitiesOnly,
           let identity = try await connection.run({ try connection.authenticateWithAgent() }) {
            return .agent(identity: identity)
        }
        if allowKeys {
            var keys: [String] = []
            switch auth {
            case .automatic:
                keys = endpoint.identityFiles
                if keys.isEmpty, defaultKeys { keys = KeyFiles.defaults(home: home.path) }
            case .keyFile: keys = endpoint.identityFiles
            case .password: break
            }
            for key in keys {
                if let login = try await logIn(connection, key: key, prompts: prompts) { return login }
            }
            if case .keyFile(let path) = auth {
                throw VFSError.failed("\(endpoint.host) did not accept the key \(path)")
            }
        }
        if case .keyFile = auth {
            throw VFSError.failed("\(endpoint.host) does not accept key logins for \(endpoint.user)")
        }
        if methods.contains("password") {
            return try await logInWithPassword(connection, prompts: prompts)
        }
        if methods.contains("keyboard-interactive") {
            return try await logInInteractively(connection, prompts: prompts)
        }
        throw VFSError.failed("Could not log in to \(endpoint.host) as \(endpoint.user) (the server offers \(methods.joined(separator: ", ")))")
    }

    private func logIn(_ connection: SSHConnection, key: String, prompts: any RemotePrompts) async throws -> SSHLogin? {
        guard KeyFiles.isEncrypted(key) else {
            let result = try await connection.run { try connection.authenticate(keyFile: key, passphrase: nil) }
            return result == .accepted ? .key(path: key, passphrase: nil) : nil
        }
        var retry = false
        for _ in 0..<3 {
            let request = SecretRequest(kind: .passphrase(keyFile: key), account: connection.endpoint.account,
                                        retry: retry, keychainKey: "ssh-key:\(key)")
            guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
            let secret = answer.secret
            switch try await connection.run({ try connection.authenticate(keyFile: key, passphrase: secret) }) {
            case .accepted:
                await prompts.secretWorked(request, answer)
                return .key(path: key, passphrase: secret)
            case .rejected:
                await prompts.secretWorked(request, answer) // the passphrase was right, the server refused the key
                return nil
            case .wrongPassphrase:
                retry = true
            }
        }
        return nil
    }

    private func passwordRequest(_ endpoint: SSHEndpoint, retry: Bool) -> SecretRequest {
        SecretRequest(kind: .password, account: endpoint.account, retry: retry, keychainKey: "sftp:\(endpoint.account)")
    }

    private func logInWithPassword(_ connection: SSHConnection, prompts: any RemotePrompts) async throws -> SSHLogin {
        var retry = false
        for _ in 0..<3 {
            let request = passwordRequest(connection.endpoint, retry: retry)
            guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
            let secret = answer.secret
            if try await connection.run({ try connection.authenticate(password: secret) }) {
                await prompts.secretWorked(request, answer)
                return .password(secret)
            }
            retry = true
        }
        throw VFSError.failed("\(connection.endpoint.host) refused the password")
    }

    /// Prompts that ask for the password are answered with the password (asked once, Keychain
    /// first); any other server question is asked as it is.
    private func logInInteractively(_ connection: SSHConnection, prompts: any RemotePrompts) async throws -> SSHLogin {
        var retry = false
        for _ in 0..<3 {
            let request = passwordRequest(connection.endpoint, retry: retry)
            let account = connection.endpoint.account
            let state = InteractiveState()
            let ok = try await connection.run {
                try connection.authenticateInteractively { questions in
                    var replies: [String] = []
                    for question in questions {
                        if question.lowercased().contains("password") {
                            guard let answer = state.password ?? Self.wait({ await prompts.secret(request) }) else {
                                state.cancelled = true
                                return nil
                            }
                            state.password = answer
                            replies.append(answer.secret)
                        } else {
                            let ask = SecretRequest(kind: .serverPrompt(question), account: account, retry: false, keychainKey: nil)
                            guard let answer = Self.wait({ await prompts.secret(ask) }) else {
                                state.cancelled = true
                                return nil
                            }
                            state.answers[question] = answer.secret
                            replies.append(answer.secret)
                        }
                    }
                    return replies
                }
            }
            if state.cancelled { throw RemoteCancelled() }
            if ok {
                if let password = state.password { await prompts.secretWorked(request, password) }
                return .keyboard(password: state.password?.secret, answers: state.answers)
            }
            retry = true
        }
        throw VFSError.failed("\(connection.endpoint.host) refused the login")
    }

    /// Answers collected during one keyboard-interactive round (only touched on the connection's queue).
    final class InteractiveState: @unchecked Sendable {
        var password: SecretAnswer?
        var answers: [String: String] = [:]
        var cancelled = false
    }

    /// Blocks the connection's queue (a dedicated thread, not the cooperative pool) until an async
    /// prompt is answered. Only used inside libssh2's keyboard-interactive callback.
    static func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    final class ResultBox<T>: @unchecked Sendable { var value: T? }

    /// The server's absolute form of `path` ("." is the login folder).
    static func realPath(_ connection: SSHConnection, _ path: String) throws -> String {
        let sftp = try connection.channel()
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = path.withCString {
            libssh2_sftp_symlink_ex(sftp, $0, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH)
        }
        guard count > 0 else { return "/" }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
