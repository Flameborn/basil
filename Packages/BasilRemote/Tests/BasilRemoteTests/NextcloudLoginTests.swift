import BasilCore
import BasilVFS
import Foundation
import Synchronization
import Testing
@testable import BasilRemote

/// Plays the browser of a Nextcloud Login Flow v2: logs in on the web page (a session of its
/// own), opens the flow page Basil asked to open, and grants access.
private struct NextcloudBrowser {
    let origin: String
    let user: String
    let password: String

    func complete(_ login: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        func page(_ url: URL) async throws -> String {
            let (data, _) = try await session.data(from: url)
            return String(decoding: data, as: UTF8.self)
        }
        func requestToken(_ html: String) throws -> String {
            let marker = try #require(html.range(of: "data-requesttoken=\""))
            return String(html[marker.upperBound...].prefix { $0 != "\"" })
        }
        func post(_ path: String, _ fields: [(String, String)], token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: origin + path)!)
            request.httpMethod = "POST"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(token, forHTTPHeaderField: "requesttoken")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let loginPage = try await page(URL(string: origin + "/login")!)
        _ = try await post("/login", [("user", user), ("password", password), ("requesttoken", try requestToken(loginPage)),
                                      ("timezone", "UTC"), ("timezone_offset", "0")], token: try requestToken(loginPage))
        let flow = try await page(login)
        let stateMarker = try #require(flow.range(of: "initial-state-core-loginFlowAuth\" value=\""))
        let encoded = String(flow[stateMarker.upperBound...].prefix { $0 != "\"" })
        let decoded = try #require(Data(base64Encoded: encoded))
        let state = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        let stateToken = try #require(state["stateToken"] as? String)
        var grant = URLComponents(string: origin + "/login/v2/grant")!
        grant.queryItems = [URLQueryItem(name: "stateToken", value: stateToken)]
        let grantPage = try await page(grant.url!)
        let token = try requestToken(grantPage)
        let status = try await post("/login/v2/grant", [("stateToken", stateToken), ("requesttoken", token)], token: token)
        #expect(status == 200)
    }
}

/// Prompts whose browser sign-in is played by `NextcloudBrowser` (or cancelled when nil).
private final class BrowserPrompts: RemotePrompts {
    let browser: NextcloudBrowser?
    let signIns = Mutex(0)
    let secretsAsked = Mutex(0)

    init(browser: NextcloudBrowser?) { self.browser = browser }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer { .cancel }
    func certificate(_ question: CertificateQuestion) async -> HostKeyAnswer { .trustOnce }
    func secret(_ request: SecretRequest) async -> SecretAnswer? {
        secretsAsked.withLock { $0 += 1 }
        return nil
    }
    func browserSignIn(_ request: BrowserSignIn) async {
        signIns.withLock { $0 += 1 }
        guard let browser else { return }
        do {
            try await browser.complete(request.url)
            // Like the sheet: it stays until the connector cancels it.
            try await Task.sleep(for: .seconds(60))
        } catch {}
    }
}

@Suite(.serialized, .enabled(if: NextcloudTestServer.shared != nil))
struct NextcloudLoginTests {
    var server: NextcloudTestServer { NextcloudTestServer.shared! }

    fileprivate func connect(_ target: RemoteTarget, secrets: MemorySecretStore, prompts: BrowserPrompts) async throws
        -> (ProviderRegistry, WebDAVProvider, VFSPath) {
        let registry = ProviderRegistry()
        let trust = TestScratch.url.appendingPathComponent("basil-trust-\(UUID().uuidString)")
        var connector = WebDAVConnector(secure: false, trustFile: trust, secrets: secrets)
        connector.pollInterval = .milliseconds(200)
        registry.register(connector: connector)
        let start = try await registry.connect(target, prompts: prompts)
        let dav = try #require(try registry.provider(for: start.location) as? WebDAVProvider)
        return (registry, dav, start)
    }

    func browserTarget(user: String?) -> RemoteTarget {
        RemoteTarget(service: .webdav, host: "127.0.0.1", port: server.port, user: user, authentication: .automatic)
    }

    @Test func signsInInTheBrowserAndKeepsTheAppPassword() async throws {
        let secrets = MemorySecretStore()
        let browser = NextcloudBrowser(origin: "http://127.0.0.1:\(server.port)", user: server.user, password: server.password)
        let prompts = BrowserPrompts(browser: browser)
        // No user typed: Nextcloud says who logged in, and the saved connection learns it.
        let (registry, dav, start) = try await connect(browserTarget(user: nil), secrets: secrets, prompts: prompts)
        #expect(prompts.signIns.withLock { $0 } == 1)
        #expect(prompts.secretsAsked.withLock { $0 } == 0)
        #expect(dav.signedInTarget?.user == server.user)
        let key = "webdav:\(server.user)@127.0.0.1:\(server.port)"
        let appPassword = try #require(secrets.secret(for: key))
        #expect(appPassword != server.password)
        _ = try await dav.list(start)
        await registry.disconnect(start.location)

        // The next connection uses the kept app password without the browser.
        let again = BrowserPrompts(browser: nil)
        let (registry2, dav2, start2) = try await connect(browserTarget(user: server.user), secrets: secrets, prompts: again)
        #expect(again.signIns.withLock { $0 } == 0)
        #expect(dav2.signedInTarget == nil)
        await registry2.disconnect(start2.location)

        // Deleting the connection revokes the app password and forgets it.
        let connector = WebDAVConnector(secure: false, trustFile: FileManager.default.temporaryDirectory
            .appendingPathComponent("basil-trust-\(UUID().uuidString)"), secrets: secrets)
        await connector.forget(browserTarget(user: server.user), remaining: [])
        #expect(secrets.secret(for: key) == nil)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/remote.php/dav/files/\(server.user)/")!)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("Basic " + Data("\(server.user):\(appPassword)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)

        // Without a kept app password, it is the browser again; cancelling stops.
        let cancelled = BrowserPrompts(browser: nil)
        await #expect(throws: RemoteCancelled.self) {
            _ = try await connect(browserTarget(user: server.user), secrets: secrets, prompts: cancelled)
        }
        #expect(cancelled.signIns.withLock { $0 } == 1)
    }

    @Test func copyLinkMakesAndReusesAPublicReadOnlyLink() async throws {
        let secrets = MemorySecretStore()
        secrets.save(server.password, for: "webdav:\(server.user)@127.0.0.1:\(server.port)")
        let (registry, dav, start) = try await connect(browserTarget(user: server.user), secrets: secrets,
                                                       prompts: BrowserPrompts(browser: nil))
        defer { Task { await registry.disconnect(start.location) } }
        #expect(dav.canShareLinks)
        let folder = start.appending("link-" + UUID().uuidString.prefix(8))
        try await dav.makeDirectory(folder)
        let file = folder.appending("shared file.txt")
        let writer = try await dav.createFile(file)
        try await writer.write(Data("shared".utf8), at: 0)
        _ = try await writer.apply(FileMetadata())
        await writer.close()

        let link = try await dav.sharedLink(for: file, lifetime: nil)
        #expect(link.path.contains("/s/"))
        #expect(try await dav.sharedLink(for: file, lifetime: nil) == link)
        let (body, response) = try await URLSession(configuration: .ephemeral).data(from: link.appendingPathComponent("download"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("shared".utf8))
        let folderLink = try await dav.sharedLink(for: folder, lifetime: nil)
        #expect(folderLink != link)
        await #expect(throws: VFSError.notFound(folder.appending("missing"))) {
            _ = try await dav.sharedLink(for: folder.appending("missing"), lifetime: nil)
        }
        try await dav.remove(file)
        try await dav.remove(folder)
    }
}
