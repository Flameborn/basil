import BasilCore
import BasilVFS
import Foundation

/// Connects to FTP servers: plain FTP, FTPS explicit (AUTH TLS, refusing to log in without it)
/// or FTPS implicit (TLS from the start). One connector is registered per kind. TLS
/// certificates the system does not trust are asked about (`CertificateTrust`). An empty user, or the
/// Anonymous option, logs in as "anonymous" without a password prompt.
public struct FTPConnector: RemoteConnector {
    public enum Kind: Sendable {
        case plain, explicitTLS, implicitTLS
    }

    public let kind: Kind
    /// Where trusted certificates are remembered.
    let trust: CertificateTrust

    /// Tests: use LIST as on servers without MLSD.
    var ignoreModernListing = false

    public init(_ kind: Kind, trustFile: URL) {
        self.kind = kind
        trust = CertificateTrust(file: trustFile)
    }

    public var service: ProviderID {
        switch kind {
        case .plain: .ftp
        case .explicitTLS: .ftpes
        case .implicitTLS: .ftps
        }
    }

    public var displayName: String {
        switch kind {
        case .plain: "FTP"
        case .explicitTLS: "FTPS (explicit)"
        case .implicitTLS: "FTPS (implicit)"
        }
    }

    public var defaultPort: Int { kind == .implicitTLS ? 990 : 21 }
    public var logins: [RemoteLogin] { [.password] }
    public var userPlaceholder: String { "Empty: anonymous" }

    /// Option keys in `RemoteTarget.options`.
    public enum Option {
        public static let activeMode = "activeMode"
        public static let anonymous = "anonymous"
        public static let encoding = "encoding"
        public static let listHidden = "listHidden"
    }

    public var options: [RemoteOption] {
        [
            RemoteOption(key: Option.anonymous, title: "Anonymous login", kind: .toggle(default: false),
                         help: "Logs in as anonymous without a password. An empty user does the same."),
            RemoteOption(key: Option.activeMode, title: "Active mode", kind: .toggle(default: false),
                         help: "The server connects back to this Mac for each transfer. Use it only when passive mode does not work."),
            RemoteOption(key: Option.encoding, title: "Name encoding",
                         kind: .choice([RemoteOption.Choice(value: FTPEncoding.utf8.rawValue, title: "UTF-8"),
                                        RemoteOption.Choice(value: FTPEncoding.windows1252.rawValue, title: "Windows-1252 (Latin-1)")],
                                       default: FTPEncoding.utf8.rawValue),
                         help: "Old servers may use Windows-1252 for names with accents."),
            RemoteOption(key: Option.listHidden, title: "Show hidden files on old servers", kind: .toggle(default: false),
                         help: "Asks servers without MLSD for files starting with a dot (LIST -a)."),
        ]
    }

    func endpoint(for target: RemoteTarget) -> FTPEndpoint {
        let given = target.user?.trimmingCharacters(in: .whitespaces) ?? ""
        let anonymous = target.flag(Option.anonymous) || given.isEmpty
        let security: FTPSecurity = switch kind {
        case .plain: .none
        case .explicitTLS: .explicit
        case .implicitTLS: .implicit
        }
        return FTPEndpoint(
            service: service,
            host: target.host,
            port: target.port ?? defaultPort,
            defaultPort: defaultPort,
            user: anonymous ? "anonymous" : given,
            security: security,
            activeMode: target.flag(Option.activeMode),
            encoding: FTPEncoding(rawValue: target.option(Option.encoding) ?? "") ?? .utf8,
            listHidden: target.flag(Option.listHidden),
            ignoreModernListing: ignoreModernListing
        )
    }

    /// Anonymous logins send this as the password, as browsers and curl do.
    static let anonymousPassword = "anonymous@"

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let endpoint = endpoint(for: target)
        var session = FTPSession(endpoint: endpoint)
        do {
            let accepted = try await open(session, prompts: prompts, accepted: nil)
            var password: String?
            var retry = false
            var tries = 0
            while true {
                do {
                    password = try await logIn(session, retry: retry, prompts: prompts)
                    break
                } catch is WrongPassword {
                    tries += 1
                    retry = true
                    if tries == 3 { throw VFSError.failed("\(endpoint.host) refused the password") }
                } catch is FTPConnectionLost {
                    tries += 1
                    if tries == 3 { throw VFSError.failed("\(endpoint.host) closed the connection while logging in") }
                }
                // Many servers close the connection after a refused password: start again.
                if session.broken {
                    let old = session
                    _ = try? await old.run { old.close() }
                    session = FTPSession(endpoint: endpoint)
                    _ = try await open(session, prompts: prompts, accepted: accepted)
                }
            }
            let ready = session
            let home = try await ready.run {
                try ready.setUp()
                return try ready.workingDirectory()
            }
            let features = try await ready.run { ready.features }
            let pool = FTPPool(endpoint: endpoint, login: FTPLogin(password: password, acceptedCertificate: accepted),
                               trust: trust, first: ready)
            let provider = FTPProvider(pool: pool, features: features, home: home)
            var startPath = home
            if let path = target.path, !path.isEmpty {
                startPath = path.hasPrefix("/") ? path : (home == "/" ? "/" : home + "/") + path
            }
            if startPath.count > 1, startPath.hasSuffix("/") { startPath.removeLast() }
            return (provider, VFSPath(location: provider.location, path: startPath))
        } catch {
            let failed = session
            _ = try? await failed.run { failed.close() }
            throw error
        }
    }

    /// Connects and checks the certificate. `accepted`: the one accepted before (a reconnect
    /// while logging in does not ask again). Returns the accepted fingerprint.
    private func open(_ session: FTPSession, prompts: any RemotePrompts, accepted: Data?) async throws -> Data? {
        let certificates = try await session.run { try session.open() }
        guard session.endpoint.security != .none else { return nil }
        if let accepted {
            try trust.verifySilently(certificates, endpoint: session.endpoint, accepted: accepted)
            return accepted
        }
        return try await trust.verify(certificates, endpoint: session.endpoint, prompts: prompts)
    }

    struct WrongPassword: Error {}

    /// One login attempt. Returns the password that worked (nil when the server needed none);
    /// throws `WrongPassword` when it was refused.
    func logIn(_ session: FTPSession, retry: Bool, prompts: any RemotePrompts) async throws -> String? {
        let endpoint = session.endpoint
        if endpoint.anonymous {
            let password = Self.anonymousPassword
            switch try await session.run({ try session.logIn(password: password) }) {
            case .loggedIn: return password
            case .refused(let text): throw VFSError.failed("\(endpoint.host) does not allow anonymous logins: \(text)")
            }
        }
        let request = SecretRequest(kind: .password, account: endpoint.account, retry: retry,
                                    keychainKey: "ftp:\(endpoint.account)")
        guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
        let secret = answer.secret
        switch try await session.run({ try session.logIn(password: secret) }) {
        case .loggedIn:
            await prompts.secretWorked(request, answer)
            return secret
        case .refused:
            throw WrongPassword()
        }
    }
}
