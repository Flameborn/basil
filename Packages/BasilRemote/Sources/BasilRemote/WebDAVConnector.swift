import BasilCore
import BasilVFS
import Foundation

/// Connects to WebDAV servers over HTTP or HTTPS (one connector each). The Start folder is the
/// folder on the server ("/dav", "/remote.php/dav/files/erion/Photos"); the connection's top
/// is the highest folder above it that still answers WebDAV, so Backspace can go up to it.
/// Nextcloud is found by its status.php: its user's files become the top
/// ("/remote.php/dav/files/<user ID>"), and its chunked uploads, dates and trash bin are used.
/// A login is asked for only when the server wants one (401); certificates the system does
/// not trust are asked about (`CertificateTrust`).
public struct WebDAVConnector: RemoteConnector {
    public let secure: Bool
    let trust: CertificateTrust

    public init(secure: Bool, trustFile: URL) {
        self.secure = secure
        trust = CertificateTrust(file: trustFile)
    }

    public var service: ProviderID { secure ? .webdavs : .webdav }
    public var displayName: String { secure ? "WebDAV (HTTPS)" : "WebDAV (HTTP)" }
    public var defaultPort: Int { secure ? 443 : 80 }
    public var logins: [RemoteLogin] { [.password] }
    public var hostPlaceholder: String { "Name or address, such as cloud.example.com" }
    public var userPlaceholder: String { "Empty: no login" }
    public var pathPlaceholder: String? { "Folder on the server, such as /dav (empty: the top)" }
    public var schemeAliases: [String] { secure ? ["https", "davs"] : ["http", "dav"] }

    func endpoint(for target: RemoteTarget) -> WebDAVEndpoint {
        WebDAVEndpoint(service: service, secure: secure, host: target.host, port: target.port ?? defaultPort,
                       defaultPort: defaultPort, user: target.user?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let endpoint = endpoint(for: target)
        let client = WebDAVClient(endpoint: endpoint)
        let session = LoginSession(connector: self, client: client, prompts: prompts)
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
            return (provider, VFSPath(location: provider.location, path: start.isEmpty ? "/" : start))
        } catch {
            client.close()
            throw error
        }
    }

    /// A Nextcloud (or ownCloud) server: the user's files are the top.
    private func nextcloud(_ found: LoginSession.Product, given: String, session: LoginSession) async throws
        -> (WebDAVProvider, String) {
        let client = session.client
        let dav = found.prefix + "/remote.php/dav"
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
        """.utf8)
        let response = try await session.send("PROPFIND", dav + "/", headers: ["Depth": "0"], body: body)
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
    let client: WebDAVClient
    let prompts: any RemotePrompts
    private var request: SecretRequest?
    private var answer: SecretAnswer?
    private var tries = 0

    init(connector: WebDAVConnector, client: WebDAVClient, prompts: any RemotePrompts) {
        self.connector = connector
        self.client = client
        self.prompts = prompts
    }

    var endpoint: WebDAVEndpoint { client.endpoint }

    /// Sends a request to a decoded server path, asking what has to be asked.
    func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws
        -> WebDAVResponse {
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
                client.accept(certificate: digest)
            } catch is WebDAVUnauthorized {
                try await askPassword()
            }
        }
    }

    private func askPassword() async throws {
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
            return Product(prefix: prefix, name: name)
        }
        return nil
    }
}
