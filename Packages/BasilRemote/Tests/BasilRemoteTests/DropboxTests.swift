import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilOperations
@testable import BasilRemote

private func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
    return data
}

private let mb = 1 << 20

private final class Once: Sendable {
    private let done = Atomic<Bool>(false)
    func callAsFunction(_ body: () throws -> Void) rethrows {
        if !done.exchange(true, ordering: .relaxed) { try body() }
    }
}

private final class Monitor: TransferMonitor {
    let lines = Mutex<[String]>([])
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) { lines.withLock { $0.append(message) } }
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}

// MARK: Pieces

@Suite struct DropboxPiecesTests {
    @Test func pkceChallengeIsTheBase64URLOfTheVerifiersSHA256() {
        let pkce = OAuthPKCE()
        #expect(pkce.verifier.count == 128)
        #expect(pkce.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(pkce.challenge == expected)
        #expect(pkce.challenge.count == 43)
        #expect(OAuthPKCE().verifier != pkce.verifier)
    }

    @Test func authorizationAddressAsksForCodeFlowWithOfflineAccess() throws {
        let auth = DropboxAuth(appKey: "k3y", hosts: .dropbox, session: .shared)
        let url = auth.authorizationURL(pkce: OAuthPKCE(), state: "st", redirect: DropboxAuth.redirectURI(port: 21745))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "www.dropbox.com" && url.path == "/oauth2/authorize")
        #expect(query["client_id"] == "k3y")
        #expect(query["redirect_uri"] == "http://localhost:21745/dropbox")
        #expect(query["response_type"] == "code" && query["code_challenge_method"] == "S256")
        #expect(query["token_access_type"] == "offline")
        #expect(query["scope"] == "account_info.read files.metadata.read files.metadata.write files.content.read files.content.write sharing.read sharing.write")
        #expect(query["state"] == "st")
    }

    @Test func contentHashFollowsDropboxsBlockScheme() {
        // No blocks: the SHA-256 of nothing.
        #expect(DropboxContentHash.of(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let data = randomData(4 * mb + 10)
        var outer = SHA256()
        outer.update(data: Data(SHA256.hash(data: data.prefix(4 * mb))))
        outer.update(data: Data(SHA256.hash(data: data.suffix(10))))
        #expect(DropboxContentHash.of(data) == outer.finalize().map { String(format: "%02x", $0) }.joined())
        // A slice that does not start at index 0 hashes the same as a copy.
        let slice = data.dropFirst(5)
        #expect(DropboxContentHash.of(slice) == DropboxContentHash.of(Data(slice)))
    }

    @Test func headerArgumentsEscapeEverythingOutsideASCII() {
        let text = DropboxProvider.headerJSON(["path": "/Caf\u{e9}/a\u{1F600}"])
        #expect(text == #"{"path":"/Caf\u00e9/a\ud83d\ude00"}"#)
        let back = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        #expect(back?["path"] == "/Caf\u{e9}/a\u{1F600}")
    }

    @Test func redirectsGoToTheSignInWithTheirState() async throws {
        let waiting = Task { try await SignInRedirects.wait(for: "abc") }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!SignInRedirects.handle(URL(string: "http://localhost:1/dropbox?code=c1&state=other")!))
        #expect(SignInRedirects.handle(URL(string: "http://localhost:1/dropbox?code=c2&state=abc")!))
        let url = try await waiting.value
        #expect(url.absoluteString.contains("code=c2"))
    }

    @Test func theReturnPageNamesTheOutcome() {
        let base = "http://localhost:1/dropbox?state=s"
        #expect(DropboxConnector.returnPage(URL(string: base + "&code=c")!, matched: true).title == "Signed in to Dropbox")
        #expect(DropboxConnector.returnPage(URL(string: base + "&error=access_denied")!, matched: true).title == "Basil was not allowed")
        let other = DropboxConnector.returnPage(URL(string: base + "&error=server_error&error_description=%3Cb%3E")!, matched: true)
        #expect(other.message.contains("<b>"))
        #expect(SignInReturnServer.html(other).contains("&lt;b&gt;") && !SignInReturnServer.html(other).contains("<b>"))
        #expect(DropboxConnector.returnPage(URL(string: base + "&code=c")!, matched: false).title == "This sign-in has ended")
    }

    @Test func aTakenPortSaysWhichAppHasIt() throws {
        let first = try SignInReturnServer(port: 0, service: "Dropbox") { _ in .init(title: "t", message: "m") }
        defer { first.stop() }
        #expect(throws: SignInReturnError.portInUse(port: first.port, app: SignInReturnServer.owner(of: first.port), service: "Dropbox")) {
            _ = try SignInReturnServer(port: first.port, service: "Dropbox") { _ in .init(title: "t", message: "m") }
        }
        // lsof names this test process.
        let message = SignInReturnError.portInUse(port: 21745, app: "Other", service: "Dropbox").errorDescription ?? ""
        #expect(message == "Basil signs in to Dropbox through port 21745 on this Mac, but Other is using it. Quit Other and connect again.")
        #expect(SignInReturnServer.owner(of: first.port) != nil)
    }

    @Test func theReturnServerAnswersOverHTTPAndStops() async throws {
        let server = try SignInReturnServer(port: 0, service: "Dropbox") { url in
            .init(title: "Got \(url.path)", message: url.query ?? "")
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:\(server.port)/dropbox?code=1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let page = String(decoding: data, as: UTF8.self)
        #expect(page.contains("<title>Basil: Got /dropbox</title>") && page.contains("code=1"))
        server.stop()
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/dropbox")!)
        }
    }

    @Test func cancellingStopsWaitingForARedirect() async {
        let waiting = Task { try await SignInRedirects.wait(for: "never") }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

// MARK: Against the fake

@Suite(.serialized) struct DropboxTests {
    struct Setup {
        let fake: FakeDropbox
        let secrets: MemorySecretStore
        let connector: DropboxConnector
        let registry: ProviderRegistry
        let provider: DropboxProvider
        let root: VFSPath
        let folder: URL
        let prompts: FakeBrowserPrompts
    }

    func setUp(prompts: FakeBrowserPrompts? = nil, path: String? = nil, teamSpace: String? = nil) async throws -> Setup {
        let fake = try FakeDropbox()
        fake.state.withLock { $0.teamSpace = teamSpace }
        let secrets = MemorySecretStore()
        let connector = DropboxConnector(appKey: FakeDropbox.appKey, secrets: secrets, hosts: fake.hosts, returnPort: 0)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: connector)
        let browser = prompts ?? FakeBrowserPrompts(fake)
        let start = try await registry.connect(RemoteTarget(service: .dropbox, host: "", path: path),
                                               prompts: browser)
        let provider = try #require(try registry.provider(for: start.location) as? DropboxProvider)
        let folder = TestScratch.url.appendingPathComponent("basil-dropbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Setup(fake: fake, secrets: secrets, connector: connector, registry: registry, provider: provider,
                     root: provider.homeDirectory, folder: folder, prompts: browser)
    }

    func engine(_ registry: ProviderRegistry, secure: Bool = true, verify: Bool = false,
                afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> SecureCopyEngine {
        SecureCopyEngine(registry: registry,
                         options: SecureCopyOptions(verifyDestination: verify, retryDelay: .milliseconds(1), secure: secure),
                         monitor: Monitor(),
                         hooks: EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.rename, .clone, .stream]))
    }

    func local(_ setup: Setup, _ name: String, _ data: Data) throws -> VFSPath {
        let url = setup.folder.appendingPathComponent(name)
        try data.write(to: url)
        return .local(url.path)
    }

    // MARK: Signing in

    @Test func signsInInTheBrowserAndKeepsTheTokenInTheKeychain() async throws {
        let s = try await setUp()
        let prompts = s.prompts
        // The browser came back to Basil's page on this Mac.
        let request = try #require(prompts.signIns.withLock { $0.first })
        let redirect = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
        #expect(redirect?.hasPrefix("http://localhost:") == true && redirect?.hasSuffix("/dropbox") == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(prompts.returnPages.withLock { $0.first?.contains("Signed in to Dropbox") } == true)
        #expect(s.secrets.secret(for: "dropbox:\(s.fake.accountID)")?.hasPrefix("refresh-") == true)
        #expect(s.provider.connectionTitle == "Dropbox (tester@example.com)")
        // The saved connection learns the account.
        let target = try #require(s.provider.signedInTarget)
        #expect(target.host == s.fake.accountID && target.user == "tester@example.com")
        #expect(s.provider.location == ProviderLocation(provider: .dropbox, instance: "tester@example.com"))
    }

    @Test func aSavedAccountConnectsWithoutTheBrowser() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        let prompts = FakeBrowserPrompts(s.fake, giveUp: true)
        let start = try await s.registry.connect(saved, prompts: prompts)
        #expect(prompts.signIns.withLock { $0.isEmpty })
        #expect(start.location.instance == "tester@example.com")
        let provider = try #require(try s.registry.provider(for: start.location) as? DropboxProvider)
        #expect(provider.signedInTarget == nil)
    }

    @Test func removedAccessSignsInAgain() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        s.fake.removeAccess()
        let prompts = FakeBrowserPrompts(s.fake)
        _ = try await s.registry.connect(saved, prompts: prompts)
        let asked = prompts.signIns.withLock { $0 }
        #expect(asked.count == 1 && asked.first?.account == "tester@example.com")
    }

    @Test func givingUpInTheBrowserCancels() async throws {
        let fake = try FakeDropbox()
        let connector = DropboxConnector(appKey: FakeDropbox.appKey, secrets: MemorySecretStore(), hosts: fake.hosts, returnPort: 0)
        await #expect(throws: RemoteCancelled.self) {
            _ = try await connector.connect(RemoteTarget(service: .dropbox, host: ""),
                                            prompts: FakeBrowserPrompts(fake, giveUp: true))
        }
    }

    @Test func expiredAccessTokensAreRefreshed() async throws {
        let s = try await setUp()
        s.fake.put("/a.txt", Data("a".utf8))
        s.fake.expireAccessTokens()
        // An SDK call (listing) and Basil's own download both refresh first.
        var names: [String] = []
        for try await batch in s.provider.list(s.root) { names += batch.map(\.name) }
        #expect(names == ["a.txt"])
        s.fake.expireAccessTokens()
        s.provider.tokens.expire()
        let reader = try await s.provider.openForReading(s.root.appending("a.txt"), bypassCache: false)
        #expect(try await reader.read(at: 0, count: 10) == Data("a".utf8))
        #expect(s.fake.state.withLock { $0.refreshes } >= 2)
    }

    @Test func forgettingRevokesUnlessAnotherConnectionUsesTheAccount() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.connector.forget(saved, remaining: [saved])
        #expect(s.secrets.secret(for: "dropbox:\(s.fake.accountID)") != nil)
        #expect(s.fake.state.withLock { $0.revokes } == 0)
        await s.connector.forget(saved, remaining: [])
        #expect(s.secrets.secret(for: "dropbox:\(s.fake.accountID)") == nil)
        #expect(s.fake.state.withLock { $0.revokes } == 1)
        #expect(s.fake.state.withLock { $0.refreshTokens.isEmpty })
    }

    @Test func aSignInWithoutTheSharingScopesSignsInAgain() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        #expect(s.secrets.secret(for: "dropbox:\(s.fake.accountID):scopes")?.contains("sharing.write") == true)
        await s.registry.disconnect(s.provider.location)
        // A sign-in kept by an earlier Basil, which asked for fewer scopes: no record of them.
        s.secrets.remove(for: "dropbox:\(s.fake.accountID):scopes")
        let prompts = FakeBrowserPrompts(s.fake)
        _ = try await s.registry.connect(saved, prompts: prompts)
        #expect(prompts.signIns.withLock { $0.count } == 1)
        #expect(s.fake.state.withLock { $0.signIns } == 2)
        // Recorded now: the next connection needs no browser.
        await s.registry.disconnect(s.provider.location)
        let quiet = FakeBrowserPrompts(s.fake, giveUp: true)
        _ = try await s.registry.connect(saved, prompts: quiet)
        #expect(quiet.signIns.withLock { $0.isEmpty })
        // Forgetting removes the record too.
        await s.connector.forget(saved, remaining: [])
        #expect(s.secrets.secret(for: "dropbox:\(s.fake.accountID):scopes") == nil)
    }

    // MARK: Shared links

    @Test func sharedLinksAreMadeOnceAndReused() async throws {
        let s = try await setUp()
        s.fake.put("/Docs/report.pdf", Data("pdf".utf8))
        let file = s.root.appending("Docs").appending("report.pdf")
        let link = try await s.provider.sharedLink(for: file)
        #expect(link.absoluteString.hasPrefix("https://www.dropbox.com/scl/fi/") && link.absoluteString.contains("report.pdf"))
        // Asked again: Dropbox says it exists, with or without its metadata.
        #expect(try await s.provider.sharedLink(for: file) == link)
        s.fake.state.withLock { $0.existingLinkWithoutMetadata = true }
        #expect(try await s.provider.sharedLink(for: file) == link)
        // Folders have links too.
        let folder = try await s.provider.sharedLink(for: s.root.appending("Docs"))
        #expect(folder != link)
        await #expect(throws: VFSError.notFound(s.root.appending("nope"))) {
            _ = try await s.provider.sharedLink(for: s.root.appending("nope"))
        }
    }

    // MARK: Files

    @Test func watchedFolderReloadsOnChangesThere() async throws {
        let s = try await setUp()
        s.fake.makeFolder("/Live")
        s.fake.makeFolder("/Other")
        let stream = try #require(s.provider.watch(s.root.appending("Live")))
        let recorder = WatchRecorder(stream)
        defer { recorder.stop() }
        // Wait until the first long-poll is waiting, then change another folder: nothing.
        let polling = ContinuousClock.now + .seconds(3)
        while s.fake.state.withLock({ $0.longpolls }) == 0, ContinuousClock.now < polling { try await Task.sleep(for: .milliseconds(20)) }
        s.fake.put("/Other/x.txt", Data("x".utf8))
        #expect(await !recorder.wait(for: 1, seconds: 0.5))
        // A new file in the watched folder reloads the pane.
        s.fake.put("/Live/new.txt", Data("n".utf8))
        #expect(await recorder.wait(for: 1, seconds: 3))
        // And the next change after it too (the cursor moved on).
        s.fake.put("/Live/second.txt", Data("2".utf8))
        #expect(await recorder.wait(for: 2, seconds: 4))
    }

    @Test func listsFoldersAcrossPagesAndReadsItems() async throws {
        let s = try await setUp()
        for i in 0..<2100 { s.fake.put(String(format: "/many/f%04d.txt", i), Data()) }
        s.fake.put("/.hidden", Data("h".utf8))
        var names: [String] = []
        for try await batch in s.provider.list(s.root.appending("many")) { names += batch.map(\.name) }
        #expect(names.count == 2100)
        let root = try await collect(s.provider.list(s.root))
        #expect(root.first { $0.name == "many" }?.kind == .directory)
        #expect(root.first { $0.name == ".hidden" }?.isHidden == true)
        let item = try await s.provider.item(at: s.root.appending(".hidden"))
        #expect(item.size == 1 && item.kind == .file)
        await #expect(throws: VFSError.notFound(s.root.appending("nope"))) {
            _ = try await collect(s.provider.list(s.root.appending("nope")))
        }
        await #expect(throws: VFSError.notADirectory(s.root.appending(".hidden"))) {
            _ = try await collect(s.provider.list(s.root.appending(".hidden")))
        }
    }

    func collect(_ stream: AsyncThrowingStream<[FileItem], Error>) async throws -> [FileItem] {
        var all: [FileItem] = []
        for try await batch in stream { all += batch }
        return all
    }

    @Test func foldersRenamesAndDeletes() async throws {
        let s = try await setUp()
        let p = s.provider
        try await p.makeDirectory(s.root.appending("Docs"))
        await #expect(throws: VFSError.alreadyExists(s.root.appending("docs"))) {
            try await p.makeDirectory(s.root.appending("docs"))
        }
        s.fake.put("/Docs/a.txt", Data("a".utf8))
        try await p.rename(s.root.appending("Docs/a.txt"), to: s.root.appending("Docs/b.txt"), replacing: false)
        #expect(s.fake.names(in: "/docs") == ["b.txt"])
        // Only the case changes.
        try await p.rename(s.root.appending("Docs/b.txt"), to: s.root.appending("Docs/B.txt"), replacing: false)
        #expect(s.fake.names(in: "/docs") == ["B.txt"])
        s.fake.put("/Docs/c.txt", Data("c".utf8))
        await #expect(throws: VFSError.alreadyExists(s.root.appending("Docs/c.txt"))) {
            try await p.rename(s.root.appending("Docs/B.txt"), to: s.root.appending("Docs/c.txt"), replacing: false)
        }
        try await p.rename(s.root.appending("Docs/B.txt"), to: s.root.appending("Docs/c.txt"), replacing: true)
        #expect(s.fake.data("/Docs/c.txt") == Data("a".utf8))
        // A folder with something in it is not removed; the Trash takes it whole.
        await #expect(throws: VFSError.directoryNotEmpty(s.root.appending("Docs"))) {
            try await p.remove(s.root.appending("Docs"))
        }
        try await p.remove(s.root.appending("Docs/c.txt"))
        try await p.remove(s.root.appending("Docs"))
        #expect(s.fake.node("/Docs") == nil)
        s.fake.put("/T/x.txt", Data("x".utf8))
        try await p.trash(s.root.appending("T"))
        #expect(s.fake.node("/T/x.txt") == nil && s.fake.node("/T") == nil)
        await #expect(throws: VFSError.notFound(s.root.appending("gone"))) {
            try await p.remove(s.root.appending("gone"))
        }
    }

    @Test func fingerprintChangesWithEveryRevision() async throws {
        let s = try await setUp()
        s.fake.put("/f.bin", Data("1234".utf8))
        let first = try await s.provider.fingerprint(of: s.root.appending("f.bin"))
        // Same size, same second on the client: still a different revision.
        s.fake.put("/f.bin", Data("abcd".utf8))
        let second = try await s.provider.fingerprint(of: s.root.appending("f.bin"))
        #expect(first.size == second.size && first != second)
    }

    @Test func copiesATreeUpAndDownKeepingDates() async throws {
        let s = try await setUp()
        let tree = s.folder.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let big = randomData(19 * mb + 77)
        try big.write(to: tree.appendingPathComponent("inner/big.bin"))
        try Data("x".utf8).write(to: tree.appendingPathComponent("small.txt"))
        try Data().write(to: tree.appendingPathComponent("empty"))
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tree.appendingPathComponent("small.txt").path)

        let up = try await engine(s.registry).transfer(.local(tree.path), to: s.root.appending("tree"), mode: .copy)
        #expect(up.failed.isEmpty)
        #expect(s.fake.data("/tree/inner/big.bin") == big)
        #expect(s.fake.data("/tree/small.txt") == Data("x".utf8))
        #expect(s.fake.data("/tree/empty") == Data())
        #expect(s.fake.node("/tree/small.txt")?.clientModified == date)
        #expect(!s.fake.names(in: "/tree").contains { $0.hasPrefix(".basil-partial-") })
        // 19 MiB in 8 MiB parts: start, append, finish.
        #expect(s.fake.state.withLock { $0.sessions.isEmpty })

        let back = s.folder.appendingPathComponent("back")
        _ = try await engine(s.registry).transfer(s.root.appending("tree"), to: .local(back.path), mode: .move)
        #expect(try Data(contentsOf: back.appendingPathComponent("inner/big.bin")) == big)
        let attributes = try FileManager.default.attributesOfItem(atPath: back.appendingPathComponent("small.txt").path)
        #expect(attributes[.modificationDate] as? Date == date)
        #expect(s.fake.node("/tree") == nil)
    }

    @Test func plainModeAndVerificationAlsoCommit() async throws {
        let s = try await setUp()
        let data = randomData(9 * mb + 1)
        let src = try local(s, "p.bin", data)
        _ = try await engine(s.registry, secure: false).transferFile(src, to: s.root.appending("p.bin"), mode: .copy,
                                                                    LocalProvider(), s.provider)
        #expect(s.fake.data("/p.bin") == data)
        _ = try await engine(s.registry, verify: true).transferFile(src, to: s.root.appending("v.bin"), mode: .copy,
                                                                   LocalProvider(), s.provider)
        #expect(s.fake.data("/v.bin") == data)
    }

    @Test func copiesInsideTheAccountOnTheServer() async throws {
        let s = try await setUp()
        let data = randomData(3 * mb)
        s.fake.put("/src.bin", data)
        let downloadsBefore = s.fake.state.withLock { $0.downloads }
        let copy = try await engine(s.registry).transferFile(s.root.appending("src.bin"), to: s.root.appending("copy.bin"),
                                                             mode: .copy, s.provider, s.provider)
        #expect(copy.strategy == .clone)
        #expect(s.fake.data("/copy.bin") == data)
        #expect(s.fake.state.withLock { $0.downloads } == downloadsBefore)
        try await s.provider.makeDirectory(s.root.appending("to"))
        let move = try await engine(s.registry).transferFile(s.root.appending("copy.bin"), to: s.root.appending("to/copy.bin"),
                                                             mode: .move, s.provider, s.provider)
        #expect(move.strategy == .rename)
        #expect(s.fake.data("/to/copy.bin") == data && s.fake.node("/copy.bin") == nil)
    }

    @Test func aTeamSpaceIsTheTopFolder() async throws {
        let s = try await setUp(teamSpace: "9001")
        s.fake.put("/Marketing/plan.txt", Data("team".utf8))
        s.fake.put("/Test User/mine.txt", Data("mine".utf8))
        let top = try await collect(s.provider.list(s.root)).map(\.name).sorted()
        #expect(top == ["Marketing", "Test User"])
        // Up, down, a server-side copy, a link and the watch, all in the team space.
        let data = randomData(9 * mb + 5)
        let src = try local(s, "up.bin", data)
        _ = try await engine(s.registry).transferFile(src, to: s.root.appending("Marketing/up.bin"), mode: .copy,
                                                     LocalProvider(), s.provider)
        #expect(s.fake.data("/Marketing/up.bin") == data)
        let back = s.folder.appendingPathComponent("back.bin")
        _ = try await engine(s.registry).transferFile(s.root.appending("Marketing/up.bin"), to: .local(back.path),
                                                     mode: .copy, s.provider, LocalProvider())
        #expect(try Data(contentsOf: back) == data)
        let copy = try await engine(s.registry).transferFile(s.root.appending("Marketing/plan.txt"),
                                                             to: s.root.appending("Test User/plan.txt"),
                                                             mode: .copy, s.provider, s.provider)
        #expect(copy.strategy == .clone && s.fake.data("/Test User/plan.txt") == Data("team".utf8))
        _ = try await s.provider.sharedLink(for: s.root.appending("Marketing/plan.txt"), lifetime: nil)
        var changes = try #require(s.provider.watch(s.root.appending("Marketing"))).makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(300))
        s.fake.put("/Marketing/new.txt", Data())
        _ = await changes.next()
        #expect(s.fake.state.withLock { $0.callsWithoutPathRoot } == [])
    }

    @Test func aPersonalAccountSendsNoPathRoot() async throws {
        let s = try await setUp()
        #expect(s.provider.teamSpace == nil)
    }

    @Test func anExistingTargetIsRefusedWhenCreating() async throws {
        let s = try await setUp()
        s.fake.put("/x.txt", Data("x".utf8))
        await #expect(throws: VFSError.alreadyExists(s.root.appending("x.txt"))) {
            _ = try await s.provider.createFile(s.root.appending("x.txt"))
        }
        // Someone else makes the name while the upload runs: the commit refuses it.
        let file = try await s.provider.createFile(s.root.appending("y.txt"))
        try await file.write(Data("mine".utf8), at: 0)
        s.fake.put("/y.txt", Data("theirs".utf8))
        await #expect(throws: VFSError.alreadyExists(s.root.appending("y.txt"))) { try await file.synchronize() }
        #expect(s.fake.data("/y.txt") == Data("theirs".utf8))
    }

    @Test func anUploadClosedWithoutMetadataIsNeverCommitted() async throws {
        let s = try await setUp()
        let file = try await s.provider.createFile(s.root.appending("z.bin"))
        try await file.write(randomData(9 * mb), at: 0)
        await file.close()
        #expect(s.fake.node("/z.bin") == nil)
    }

    // Local source changing while it is uploaded: Dropbox has no random-access writes, so the
    // partial file is written again from the start.

    @Test func localSourceAppendedDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: s.root.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.data("/a.bin") == Data(contentsOf: URL(fileURLWithPath: src.path)))
        #expect(s.fake.names(in: "").filter { $0.hasPrefix(".basil-partial-") }.isEmpty)
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(src, to: s.root.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        let copied = try #require(s.fake.data("/a.bin"))
        let original = try Data(contentsOf: URL(fileURLWithPath: src.path))
        #expect(copied.count == mb + 1000 && copied == original)
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: s.root.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.data("/a.bin") == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    // A Dropbox source changing during a download. Each read pass reads one revision; the new
    // revision is seen whatever its size or time.

    func download(_ s: Setup, _ name: String, change: @escaping @Sendable () -> Void) async throws -> FileTransferResult {
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 1 { once { change() } }
        }
        let target = VFSPath.local(s.folder.appendingPathComponent(name).path)
        return try await copy.transferFile(s.root.appending(name), to: target, mode: .copy, s.provider, LocalProvider())
    }

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let s = try await setUp()
        let original = randomData(3 * mb + 100)
        s.fake.put("/r.bin", original)
        let more = randomData(mb)
        let result = try await download(s, "r.bin") { s.fake.put("/r.bin", original + more) }
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("r.bin")) == original + more)
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let s = try await setUp()
        let original = randomData(4 * mb)
        s.fake.put("/r.bin", original)
        let result = try await download(s, "r.bin") { s.fake.put("/r.bin", original.prefix(2 * mb + 5)) }
        #expect(result.retries == 1)
        let copied = try Data(contentsOf: s.folder.appendingPathComponent("r.bin"))
        #expect(copied.count == 2 * mb + 5 && copied == original.prefix(2 * mb + 5))
    }

    @Test func remoteSourceRewrittenAtTheSameSizeDuringDownload() async throws {
        let s = try await setUp()
        var data = randomData(3 * mb)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        s.fake.put("/r.bin", data, modified: date)
        data.replaceSubrange(100..<150, with: randomData(50))
        let changed = data
        let result = try await download(s, "r.bin") { s.fake.put("/r.bin", changed, modified: date) }
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("r.bin")) == changed)
    }

    @Test func readsAtOffsetsAcrossWindows() async throws {
        let s = try await setUp()
        let data = randomData(17 * mb + 3)
        s.fake.put("/w.bin", data)
        let reader = try await s.provider.openForReading(s.root.appending("w.bin"), bypassCache: false)
        #expect(try await reader.read(at: Int64(8 * mb - 10), count: 20) == data.subdata(in: (8 * mb - 10)..<(8 * mb + 10)))
        #expect(try await reader.read(at: 5, count: 5) == data.subdata(in: 5..<10))
        #expect(try await reader.read(at: Int64(17 * mb), count: 100) == data.suffix(3))
        #expect(try await reader.read(at: Int64(data.count), count: 100).isEmpty)
        await reader.close()
    }
}
