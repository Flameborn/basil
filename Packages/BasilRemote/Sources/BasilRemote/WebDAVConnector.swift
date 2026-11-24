import BasilCore
import BasilVFS
import Foundation

/// Connects to WebDAV servers over HTTP or HTTPS (one connector each). The Start folder is the
/// folder on the server ("/dav", "/remote.php/dav/files/erion/Photos"); the connection's top
/// is the highest folder above it that still answers WebDAV, so Backspace can go up to it.
/// Nextcloud is found by its status.php: its user's files become the top
/// ("/remote.php/dav/files/<user ID>"), and its chunked uploads, dates and trash bin are used.
/// A login is asked for only when the server wants one (401); certificates the system does
/// not trust are asked about (`CertificateTrust`). With the automatic login, Nextcloud is signed
/// in in the browser (its Login Flow v2): Basil gets an app password, kept in the Keychain, so
/// accounts with two-factor logins work too.
public struct WebDAVConnector: RemoteConnector {
    public let secure: Bool
    let trust: CertificateTrust
    /// Where app passwords from the browser sign-in are kept (nil: not kept).
    let secrets: (any SecretStore)?
    /// How often the browser sign-in asks Nextcloud whether it is done.
    var pollInterval: Duration = .seconds(1)

    public init(secure: Bool, trustFile: URL, secrets: (any SecretStore)? = nil) {
        self.secure = secure
        self.secrets = secrets
        trust = CertificateTrust(file: trustFile)
    }

    public var service: ProviderID { secure ? .webdavs : .webdav }
    public var displayName: String { secure ? "WebDAV (HTTPS)" : "WebDAV (HTTP)" }
    public var defaultPort: Int { secure ? 443 : 80 }
    public var logins: [RemoteLogin] { [.automatic, .password] }
    public var automaticLoginTitle: String { "Browser sign-in on Nextcloud, else password" }
    public var hostPlaceholder: String { "Name or address, such as cloud.example.com" }
    public var userPlaceholder: String { "Empty: no login" }
    public var pathPlaceholder: String? { "Folder on the server, such as /dav (empty: the top)" }
    public var schemeAliases: [String] { secure ? ["https", "davs"] : ["http", "dav"] }

    func endpoint(for target: RemoteTarget) -> HTTPEndpoint {
        HTTPEndpoint(service: service, secure: secure, host: target.host, port: target.port ?? defaultPort,
                       defaultPort: defaultPort, user: target.user?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let endpoint = endpoint(for: target)
        let client = HTTPClient(endpoint: endpoint)
        let session = LoginSession(connector: self, client: client, prompts: prompts,
                                   browser: target.authentication == .automatic)
        do {
            let given = DAVPath.normalized(target.path)
            let provider: WebDAVProvider
            let start: String
            if let found = try await session.nextcloud(near: given) {
                (provider, start) = try await nextcloud(found, given: given, session: session)
            } else {
                (provider, start) = try await plain(given: given, session: session)
            }
            await session.loggedIn()
            if let login = session.browserLogin, login != target.user {
                // The account Nextcloud signed in, written back to the saved connection.
                var signedIn = target
                signedIn.user = login
                provider.signedIn = signedIn
            }
            return (provider, VFSPath(location: provider.location, path: start.isEmpty ? "/" : start))
        } catch {
            session.client.close()
            if session.client !== client { client.close() }
            throw error
        }
    }

    /// A Nextcloud (or ownCloud) server: the user's files are the top.
    private func nextcloud(_ found: LoginSession.Product, given: String, session: LoginSession) async throws
        -> (WebDAVProvider, String) {
        var client = session.client
        let dav = found.prefix + "/remote.php/dav"
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
        """.utf8)
        let response = try await session.send("PROPFIND", dav + "/", headers: ["Depth": "0"], body: body)
        // A browser sign-in may have logged in as another user name (a new client).
        client = session.client
        guard response.status == 207 else {
            throw VFSError.failed("\(client.endpoint.hostAndPort) runs \(found.name) but its WebDAV did not answer: \(response.problem)")
        }
        // <d:current-user-principal><d:href>/remote.php/dav/principals/users/erion/</d:href>
        let text = String(decoding: response.body, as: UTF8.self)
        guard let marker = text.range(of: "/principals/users/") else {
            throw VFSError.failed("\(client.endpoint.hostAndPort) did not say which \(found.name) user logged in")
        }
        let id = text[marker.upperBound...].prefix { $0 != "/" && $0 != "<" }
        let userID = String(id).removingPercentEncoding ?? String(id)
        var server = NextcloudServer(prefix: found.prefix, userID: userID, trash: false)
        let files = dav + "/files/" + userID
        // The start folder: below the user's files, or below the old /remote.php/webdav.
        var start = ""
        for base in [files, found.prefix + "/remote.php/webdav"] where given.hasPrefix(base + "/") {
            start = String(given.dropFirst(base.count))
        }
        if found.isNextcloud {
            let trash = try await session.send("PROPFIND", server.trashBin + "/", headers: ["Depth": "0"])
            server.trash = trash.status == 207
        }
        let identity = client.endpoint.account + found.prefix
        let provider = WebDAVProvider(client: client, root: files,
                                      nextcloud: found.isNextcloud ? server : nil, identity: identity)
        return (provider, start)
    }

    /// Any other server: the given folder must answer; the top is the highest folder above it
    /// that still does.
    private func plain(given: String, session: LoginSession) async throws -> (WebDAVProvider, String) {
        let client = session.client
        let host = client.endpoint.hostAndPort
        let shown = given.isEmpty ? "/" : given
        let response = try await session.send("PROPFIND", given + "/", headers: ["Depth": "0"],
                                              body: DAVXML.propfind(nextcloud: false))
        switch response.status {
        case 207:
            break
        case 404:
            throw VFSError.failed("\(host) has no folder \(shown)")
        case 405, 501:
            throw VFSError.failed("\(host) does not offer WebDAV at \(shown). Check the Start folder (for example /dav or /remote.php/dav).")
        default:
            throw VFSError.failed("\(host) refused \(shown): \(response.problem)")
        }
        let entries = (try? DAVXML.parse(response.body)) ?? []
        guard let first = entries.first(where: { DAVPath.decode($0.href) == given }) ?? entries.first else {
            throw VFSError.failed("\(host) does not offer WebDAV at \(shown)")
        }
        guard first.isCollection else { throw VFSError.failed("\(shown) on \(host) is a file, not a folder") }
        var root = given
        while let parent = DAVPath.parent(root) {
            guard let answer = try? await session.send("PROPFIND", parent + "/", headers: ["Depth": "0"],
                                                       body: DAVXML.propfind(nextcloud: false)),
                  answer.status == 207,
                  let entries = try? DAVXML.parse(answer.body),
                  entries.first(where: { DAVPath.decode($0.href) == parent })?.isCollection == true
            else { break }
            root = parent
        }
        let provider = WebDAVProvider(client: client, root: root, nextcloud: nil,
                                      identity: client.endpoint.account + root)
        return (provider, String(given.dropFirst(root.count)))
    }
}

/// The requests made while connecting: they ask about an untrusted certificate (once) and
/// for the password whenever the server answers 401 (three tries).
final class LoginSession: @unchecked Sendable {
    let connector: WebDAVConnector
    /// Replaced when a browser sign-in names another user than the target's.
    private(set) var client: HTTPClient
    let prompts: any RemotePrompts
    /// The automatic login: Nextcloud signs in in the browser.
    let browser: Bool
    private var request: SecretRequest?
    private var answer: SecretAnswer?
    private var tries = 0
    /// The Nextcloud found by `nextcloud(near:)`.
    private var product: Product?
    private var storedTried = false
    private var browserTried = false
    private var acceptedCertificate: Data?
    /// The login name of a browser sign-in that worked.
    private(set) var browserLogin: String?

    init(connector: WebDAVConnector, client: HTTPClient, prompts: any RemotePrompts, browser: Bool = false) {
        self.connector = connector
        self.client = client
        self.prompts = prompts
        self.browser = browser
    }

    private var keychainKey: String { "\(endpoint.service.rawValue):\(endpoint.account)" }

    var endpoint: HTTPEndpoint { client.endpoint }

    /// Sends a request to a decoded server path, asking what has to be asked.
    func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws
        -> HTTPResponse {
        var headers = headers
        if body != nil { headers["Content-Type"] = "application/xml; charset=utf-8" }
        let url = URL(string: endpoint.origin + DAVPath.encode(path))!
        var askedCertificate = false
        while true {
            do {
                return try await client.send(method, url, headers: headers, body: body)
            } catch let untrusted as UntrustedCertificate {
                guard !askedCertificate else { throw VFSError.failed("\(endpoint.hostAndPort) sent another TLS certificate") }
                askedCertificate = true
                let digest = try await connector.trust.verify(untrusted.chain, host: endpoint.host,
                                                              hostAndPort: endpoint.hostAndPort, prompts: prompts)
                acceptedCertificate = digest
                client.accept(certificate: digest)
            } catch is HTTPUnauthorized {
                try await askPassword()
            }
        }
    }

    private func askPassword() async throws {
        if browser, let product, product.isNextcloud, !browserTried {
            // An app password from an earlier browser sign-in, then a new sign-in.
            if !storedTried, !endpoint.user.isEmpty, let stored = connector.secrets?.secret(for: keychainKey) {
                storedTried = true
                client.password = stored
                return
            }
            browserTried = true
            try await signInInBrowser(prefix: product.prefix)
            return
        }
        guard !endpoint.user.isEmpty else {
            throw VFSError.failed("\(endpoint.hostAndPort) asks for a login. Edit the connection and fill in User.")
        }
        if tries == 3 { throw VFSError.failed("\(endpoint.hostAndPort) refused the password") }
        let request = SecretRequest(kind: .password, account: endpoint.account, retry: tries > 0,
                                    keychainKey: "\(endpoint.service.rawValue):\(endpoint.account)")
        tries += 1
        guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
        self.request = request
        self.answer = answer
        client.password = answer.secret
    }

    /// Nextcloud's Login Flow v2: the browser opens Nextcloud's sign-in page (which handles
    /// two-factor logins), Basil asks Nextcloud every second whether it is done and gets the login
    /// name and a new app password, which is kept in the Keychain.
    private func signInInBrowser(prefix: String) async throws {
        let start = try await client.send("POST", URL(string: endpoint.origin + prefix + "/index.php/login/v2")!,
                                          headers: ["User-Agent": "Basil (Mac)", "Accept": "application/json"], body: Data())
        guard start.status == 200,
              let json = try? JSONSerialization.jsonObject(with: start.body) as? [String: Any],
              let poll = json["poll"] as? [String: Any], let token = poll["token"] as? String,
              let pollAddress = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
              let login = (json["login"] as? String).flatMap(URL.init(string:)) else {
            throw VFSError.failed("\(endpoint.hostAndPort) did not start a browser sign-in: \(start.problem). Choose Password in the connection to log in with a password or app password.")
        }
        // Asked at the server Basil talks to, even when Nextcloud names itself differently.
        let pollURL = URL(string: endpoint.origin + pollAddress.path)!
        let request = BrowserSignIn(service: "Nextcloud", url: login, account: endpoint.user.isEmpty ? nil : endpoint.account)
        enum Outcome: Sendable { case done(String, String), cancelled, failed(String) }
        let client = client, interval = connector.pollInterval, host = endpoint.hostAndPort
        let prompts = prompts
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let body = Data(("token=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)).utf8)
                let deadline = Date().addingTimeInterval(20 * 60)
                while !Task.isCancelled, Date() < deadline {
                    if let answer = try? await client.send("POST", pollURL, headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                                                     "Accept": "application/json"], body: body) {
                        if answer.status == 200,
                           let json = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any],
                           let name = json["loginName"] as? String, let password = json["appPassword"] as? String {
                            return .done(name, password)
                        }
                        if answer.status != 404 { return .failed("\(host) ended the browser sign-in: \(answer.problem)") }
                    }
                    try? await Task.sleep(for: interval)
                }
                return .failed("The browser sign-in at \(host) took longer than 20 minutes")
            }
            group.addTask {
                await prompts.browserSignIn(request)
                return .cancelled
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        switch outcome {
        case .cancelled: throw RemoteCancelled()
        case .failed(let message): throw VFSError.failed(message)
        case .done(let name, let password):
            if name != endpoint.user {
                var signedIn = endpoint
                signedIn.user = name
                let replacement = HTTPClient(endpoint: signedIn)
                replacement.accept(certificate: acceptedCertificate)
                self.client.close()
                self.client = replacement
            }
            self.client.password = password
            browserLogin = name
            connector.secrets?.save(password, for: keychainKey)
        }
    }

    /// The connection is made: save the password if the user asked to.
    func loggedIn() async {
        if let request, let answer { await prompts.secretWorked(request, answer) }
    }

    /// A Nextcloud or ownCloud server near the given path.
    struct Product {
        var prefix: String
        var name: String
        var isNextcloud: Bool { name.lowercased().contains("nextcloud") }
    }

    /// Looks for status.php where the given path says Nextcloud is ("/nextcloud/remote.php/...":
    /// "/nextcloud"), else at the given path and at the server's top.
    func nextcloud(near given: String) async throws -> Product? {
        var candidates: [String] = []
        if let range = given.range(of: "/remote.php/") ?? (given.hasSuffix("/remote.php") ? given.range(of: "/remote.php") : nil) {
            candidates.append(String(given[..<range.lowerBound]))
        } else {
            candidates.append(given)
            if !given.isEmpty { candidates.append("") }
        }
        for prefix in candidates {
            let response = try await send("GET", prefix + "/status.php")
            guard response.status == 200,
                  let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  json["installed"] as? Bool == true
            else { continue }
            let name = json["productname"] as? String ?? "ownCloud"
            product = Product(prefix: prefix, name: name)
            return product
        }
        return nil
    }
}

extension WebDAVConnector {
    public func isUnencrypted(_ target: RemoteTarget) -> Bool { !secure }

    /// A deleted connection that signed in in the browser: its app password is revoked on the
    /// server and removed from the Keychain, unless another saved connection uses the same
    /// account. (A login password kept by the password prompt is refused by Nextcloud's revoke
    /// call, so it stays valid on the server.)
    public func forget(_ target: RemoteTarget, remaining: [RemoteTarget]) async {
        guard target.authentication == .automatic, let secrets else { return }
        let endpoint = endpoint(for: target)
        guard !endpoint.user.isEmpty else { return }
        let same = remaining.contains { other in
            other.service == target.service && self.endpoint(for: other).account == endpoint.account
        }
        let key = "\(endpoint.service.rawValue):\(endpoint.account)"
        guard !same, let password = secrets.secret(for: key) else { return }
        secrets.remove(for: key)
        let client = HTTPClient(endpoint: endpoint)
        defer { client.close() }
        client.password = password
        let session = LoginSession(connector: self, client: client, prompts: SilentPrompts())
        guard let product = try? await session.nextcloud(near: DAVPath.normalized(target.path)), product.isNextcloud else { return }
        _ = try? await client.send("DELETE", URL(string: endpoint.origin + product.prefix + "/ocs/v2.php/core/apppassword")!,
                                   headers: ["OCS-APIRequest": "true", "Accept": "application/json",
                                             "Authorization": "Basic " + Data("\(endpoint.user):\(password)".utf8).base64EncodedString()])
    }
}

/// Answers nothing (revoking after a connection was deleted: nobody to ask).
struct SilentPrompts: RemotePrompts {
    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer { .cancel }
    func secret(_ request: SecretRequest) async -> SecretAnswer? { nil }
}
