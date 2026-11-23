import BasilCore
import BasilVFS
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
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) {}
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}

/// QuickXorHash by its definition, one bit position at a time: byte k is XORed into a 160-bit
/// circular value at bit (11 * k) mod 160, then the length goes into the last 8 bytes.
private func referenceQuickXor(_ data: Data) -> String {
    var bits = [UInt8](repeating: 0, count: 20)
    for (k, byte) in data.enumerated() {
        for bit in 0..<8 where byte & (1 << bit) != 0 {
            let position = (11 * k + bit) % 160
            bits[position / 8] ^= 1 << (position % 8)
        }
    }
    let length = UInt64(data.count)
    for index in 0..<8 { bits[12 + index] ^= UInt8((length >> (8 * UInt64(index))) & 0xff) }
    return Data(bits).base64EncodedString()
}

// MARK: Pieces

@Suite struct OneDrivePiecesTests {
    @Test func authorizationAddressUsesTheCommonTenantWithPKCE() throws {
        let auth = MicrosoftAuth(clientID: "abc", hosts: .microsoft, session: .shared)
        let url = auth.authorizationURL(pkce: OAuthPKCE(), state: "st", redirect: MicrosoftAuth.redirectURI(port: 50123), account: nil)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "login.microsoftonline.com" && url.path == "/common/oauth2/v2.0/authorize")
        #expect(query["client_id"] == "abc" && query["redirect_uri"] == "http://localhost:50123/onedrive")
        #expect(query["response_type"] == "code" && query["code_challenge_method"] == "S256" && query["response_mode"] == "query")
        #expect(query["scope"] == "Files.ReadWrite.All offline_access User.Read")
        #expect(query["prompt"] == "select_account" && query["login_hint"] == nil)
        let hinted = auth.authorizationURL(pkce: OAuthPKCE(), state: "st", redirect: "r", account: "me+x@example.com")
        #expect(hinted.absoluteString.contains("login_hint=me%2Bx@example.com") && !hinted.absoluteString.contains("prompt="))
    }

    @Test func grantedScopesAreReadWithOrWithoutGraphsPrefix() {
        #expect(MicrosoftScopes.covered(by: "https://graph.microsoft.com/Files.ReadWrite.All https://graph.microsoft.com/User.Read"))
        #expect(MicrosoftScopes.covered(by: "files.readwrite.all User.Read profile openid"))
        #expect(!MicrosoftScopes.covered(by: "Files.Read User.Read"))
        #expect(!MicrosoftScopes.covered(by: nil))
    }

    @Test func quickXorHashFollowsItsDefinition() {
        #expect(QuickXorHash().base64 == "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        for size in [1, 7, 159, 160, 161, 320, 1000, 100_003] {
            let data = randomData(size)
            var whole = QuickXorHash()
            whole.update(data)
            #expect(whole.base64 == referenceQuickXor(data), "size \(size)")
            // Fed in uneven pieces, the result is the same.
            var pieces = QuickXorHash()
            var start = 0
            var step = 1
            while start < data.count {
                pieces.update(data.subdata(in: start..<min(start + step, data.count)))
                start += step
                step = step * 3 + 1
            }
            #expect(pieces.base64 == whole.base64, "size \(size) in pieces")
        }
    }

    /// Values from rclone's QuickXorHash (`rclone hashsum quickxor --base64`, its URL-safe
    /// Base64 turned into the standard alphabet OneDrive uses).
    @Test func quickXorHashMatchesRclone() {
        func hash(_ data: Data) -> String {
            var hasher = QuickXorHash()
            hasher.update(data)
            return hasher.base64
        }
        #expect(hash(Data()) == "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        #expect(hash(Data("a".utf8)) == "YQAAAAAAAAAAAAAAAQAAAAAAAAA=")
        #expect(hash(Data("Hello, world".utf8)) == "SCgDG9jwBhaA4A5vnAMbyAAAAAA=")
        let seq1000 = Data((0..<1000).map { (i: Int) -> UInt8 in UInt8(i % 251) })
        let seq200k = Data((0..<200_000).map { (i: Int) -> UInt8 in UInt8((i * 7 + 3) % 256) })
        let count3m = 3 * 1024 * 1024 + 17
        let seq3m = Data((0..<count3m).map { (i: Int) -> UInt8 in UInt8((i * 13 + i / 7) % 256) })
        #expect(hash(seq1000) == "KbphcpColXb1/3Wm950vUzeX1es=")
        #expect(hash(seq200k) == "UDaz+YSVrQw+YhHrw4BvRPpkJxs=")
        #expect(hash(seq3m) == "Gv1aVj2hgG8ZIup0DafBGKE3jJM=")
    }

    @Test func namesAreEncodedAndForbiddenCharactersRefused() {
        #expect(GraphPath.encode("a b#%?.txt") == "a%20b%23%25%3F.txt")
        #expect(GraphPath.encode("b!drive") == "b%21drive")
        #expect(GraphPath.problem(with: "a:b") != nil && GraphPath.problem(with: "what?") != nil)
        #expect(GraphPath.problem(with: "notes #1 (final).txt") == nil)
    }

    @Test func aSharedFolderAddedToMyFilesIsALinkIntoItsDrive() throws {
        let json = #"""
        {"id": "link1", "name": "Team", "parentReference": {"driveId": "mine", "id": "root"},
         "remoteItem": {"id": "f9", "name": "Team files", "folder": {"childCount": 2}, "parentReference": {"driveId": "theirs"}}}
        """#
        let item = try JSONDecoder().decode(GraphItem.self, from: Data(json.utf8))
        let ref = OneDriveRef.of(item, drive: "mine")
        #expect(ref.kind == .folderLink && ref.isLink)
        #expect(ref.ownDrive == "mine" && ref.ownID == "link1" && ref.contentDrive == "theirs" && ref.contentID == "f9")
    }
}

// MARK: Against the fake

@Suite(.serialized) struct OneDriveTests {
    struct Setup {
        let fake: FakeOneDrive
        let secrets: MemorySecretStore
        let connector: OneDriveConnector
        let registry: ProviderRegistry
        let provider: OneDriveProvider
        let start: VFSPath
        let folder: URL
        let prompts: MicrosoftBrowserPrompts
        var top: VFSPath { provider.homeDirectory }
    }

    func setUp(path: String? = nil, business: Bool = false, fill: ((FakeOneDrive) -> Void)? = nil) async throws -> Setup {
        let fake = try FakeOneDrive()
        fake.state.withLock { $0.business = business }
        fill?(fake)
        let secrets = MemorySecretStore()
        let connector = OneDriveConnector(clientID: FakeOneDrive.clientID, secrets: secrets, hosts: fake.hosts)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: connector)
        let prompts = MicrosoftBrowserPrompts(fake)
        let start = try await registry.connect(RemoteTarget(service: .oneDrive, host: "", path: path), prompts: prompts)
        let provider = try #require(try registry.provider(for: start.location) as? OneDriveProvider)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-onedrive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Setup(fake: fake, secrets: secrets, connector: connector, registry: registry, provider: provider,
                     start: start, folder: folder, prompts: prompts)
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

    func collect(_ stream: AsyncThrowingStream<[FileItem], Error>) async throws -> [FileItem] {
        var all: [FileItem] = []
        for try await batch in stream { all += batch }
        return all
    }

    func names(_ s: Setup, _ path: VFSPath) async throws -> [String] {
        try await collect(s.provider.list(path)).map(\.name).sorted()
    }

    // MARK: Signing in

    @Test func signsInInTheBrowserAndKeepsTheTokenInTheKeychain() async throws {
        let s = try await setUp()
        let request = try #require(s.prompts.signIns.withLock { $0.first })
        let redirect = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
        #expect(redirect?.hasPrefix("http://localhost:") == true && redirect?.hasSuffix("/onedrive") == true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(s.prompts.returnPages.withLock { $0.first?.contains("Signed in to OneDrive") } == true)
        #expect(s.secrets.secret(for: "onedrive:\(s.fake.userID)")?.hasPrefix("refresh-") == true)
        #expect(s.provider.connectionTitle == "OneDrive (tester@example.com)")
        let target = try #require(s.provider.signedInTarget)
        #expect(target.host == s.fake.userID && target.user == "tester@example.com")
        #expect(s.start.path == "/")
    }

    @Test func aSavedAccountConnectsWithoutTheBrowserAndKeepsTheNewRefreshToken() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        for _ in 0..<2 {
            let quiet = MicrosoftBrowserPrompts(s.fake, giveUp: true)
            let start = try await s.registry.connect(saved, prompts: quiet)
            #expect(quiet.signIns.withLock { $0.isEmpty })
            #expect(start.location.instance == "tester@example.com")
            // Each refresh replaced the refresh token; the Keychain has the one that works.
            let stored = try #require(s.secrets.secret(for: "onedrive:\(s.fake.userID)"))
            #expect(s.fake.state.withLock { $0.refreshTokens.contains(stored) })
            await s.registry.disconnect(start.location)
        }
        #expect(s.fake.state.withLock { $0.refreshes } == 2)
    }

    @Test func refreshTokensReplacedWhileConnectedAreStored() async throws {
        let s = try await setUp { $0.put("a.txt", Data("a".utf8)) }
        s.fake.expireAccessTokens()
        #expect(try await names(s, s.top) == ["a.txt"])
        let stored = try #require(s.secrets.secret(for: "onedrive:\(s.fake.userID)"))
        #expect(s.fake.state.withLock { $0.refreshTokens.contains(stored) && $0.refreshes == 1 })
    }

    @Test func removedAccessSignsInAgainWithTheAccountAsHint() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        s.fake.removeAccess()
        let prompts = MicrosoftBrowserPrompts(s.fake)
        _ = try await s.registry.connect(saved, prompts: prompts)
        let asked = try #require(prompts.signIns.withLock { $0.first })
        #expect(asked.url.absoluteString.contains("login_hint=tester@example.com"))
    }

    @Test func aSignInWithoutTheFilesPermissionFails() async throws {
        let fake = try FakeOneDrive()
        fake.state.withLock { $0.grantedScopes = "User.Read openid" }
        let secrets = MemorySecretStore()
        let connector = OneDriveConnector(clientID: FakeOneDrive.clientID, secrets: secrets, hosts: fake.hosts)
        await #expect(throws: VFSError.self) {
            _ = try await connector.connect(RemoteTarget(service: .oneDrive, host: ""), prompts: MicrosoftBrowserPrompts(fake))
        }
        #expect(secrets.secret(for: "onedrive:\(fake.userID)") == nil)
    }

    @Test func givingUpInTheBrowserCancels() async throws {
        let fake = try FakeOneDrive()
        let connector = OneDriveConnector(clientID: FakeOneDrive.clientID, secrets: MemorySecretStore(), hosts: fake.hosts)
        await #expect(throws: RemoteCancelled.self) {
            _ = try await connector.connect(RemoteTarget(service: .oneDrive, host: ""), prompts: MicrosoftBrowserPrompts(fake, giveUp: true))
        }
    }

    @Test func expiredAccessTokensAndRateLimitsAreHandled() async throws {
        let s = try await setUp { $0.put("a.txt", Data("a".utf8)) }
        s.fake.expireAccessTokens()
        s.fake.state.withLock { $0.rateLimited = 2 }
        let reader = try await s.provider.openForReading(s.top.appending("a.txt"), bypassCache: false)
        #expect(try await reader.read(at: 0, count: 10) == Data("a".utf8))
        await reader.close()
        // A request the client does not send again by itself (a rename) waits too.
        s.fake.state.withLock { $0.rateLimited = 1 }
        try await s.provider.rename(s.top.appending("a.txt"), to: s.top.appending("b.txt"), replacing: false)
        #expect(s.fake.child("b.txt") != nil)
        #expect(s.fake.state.withLock { $0.refreshes } >= 1 && s.fake.state.withLock { $0.rateLimited } == 0)
    }

    @Test func forgettingRemovesTheSignInUnlessAnotherConnectionUsesTheAccount() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.connector.forget(saved, remaining: [saved])
        #expect(s.secrets.secret(for: "onedrive:\(s.fake.userID)") != nil)
        await s.connector.forget(saved, remaining: [])
        #expect(s.secrets.secret(for: "onedrive:\(s.fake.userID)") == nil)
        #expect(s.secrets.secret(for: "onedrive:\(s.fake.userID):scopes") == nil)
    }

    // MARK: Listing and links

    @Test func listsEveryPageAndStartsInAStartFolder() async throws {
        let s = try await setUp(path: "/Documents") { fake in
            let docs = fake.folder("Documents")
            for index in 1...8 { fake.put("file\(index).txt", in: docs, Data(repeating: 1, count: index)) }
        }
        #expect(s.start.path == "/Documents")
        let items = try await collect(s.provider.list(s.start))
        #expect(items.count == 8)
        #expect(items.first { $0.name == "file5.txt" }?.size == 5)
        // Names are found without regard to case, as OneDrive keeps them.
        #expect(try await s.provider.item(at: s.top.appending("documents")).kind == .directory)
        await #expect(throws: VFSError.notFound(s.top.appending("Nothing"))) { _ = try await s.provider.item(at: s.top.appending("Nothing")) }
    }

    @Test func personalVaultIsListedButExplainsWhyItCannotBeOpened() async throws {
        let s = try await setUp { fake in fake.vault() }
        let vault = s.top.appending("Personal Vault")
        #expect(try await collect(s.provider.list(s.top)).contains { $0.name == "Personal Vault" })
        await #expect(throws: VFSError.failed("Personal Vault can't be opened by other apps. Use onedrive.com or the OneDrive app.")) {
            _ = try await collect(s.provider.list(vault))
        }
    }

    @Test func sharedFoldersInMyFilesAreLinksIntoTheirDrive() async throws {
        var shared = (link: "", folder: "")
        let s = try await setUp { fake in
            shared = fake.sharedFolder("Team")
            fake.put("plan.txt", in: shared.folder, Data("p".utf8))
            fake.put("mine.txt", Data("m".utf8))
        }
        let items = try await collect(s.provider.list(s.top))
        #expect(items.first { $0.name == "Team" }?.kind == .symlink(target: .directory))
        #expect(try await names(s, s.top.appending("Team")) == ["plan.txt"])
        #expect(try await s.provider.readSymlink(s.top.appending("Team")).contains("Team"))
        // Each drive is its own volume, so a move into the shared folder copies and deletes.
        let mine = try await s.provider.volumeIdentifier(of: s.top.appending("mine.txt"))
        let theirs = try await s.provider.volumeIdentifier(of: s.top.appending("Team").appending("new.txt"))
        #expect(mine != theirs)
        _ = try await engine(s.registry).transfer(s.top.appending("mine.txt"), to: s.top.appending("Team").appending("mine.txt"), mode: .move)
        #expect(s.fake.child("mine.txt", in: shared.folder)?.data == Data("m".utf8))
        #expect(s.fake.child("mine.txt") == nil)
        // Deleting the link removes only the link.
        #expect(try await s.provider.fingerprint(of: s.top.appending("Team")).kind == .symlink)
        try await s.provider.remove(s.top.appending("Team"))
        #expect(s.fake.child("plan.txt", in: shared.folder) != nil)
        #expect(s.fake.child("Team") == nil)
    }

    // MARK: Changes

    @Test func foldersRenamesMovesCopiesAndDeletes() async throws {
        let s = try await setUp { $0.put("a.txt", Data("a".utf8)) }
        let p = s.provider
        let top = s.top
        try await p.makeDirectory(top.appending("Docs"))
        await #expect(throws: VFSError.alreadyExists(top.appending("Docs"))) { try await p.makeDirectory(top.appending("Docs")) }
        await #expect(throws: VFSError.self) { try await p.makeDirectory(top.appending("a:b")) }
        // Move into a folder, then copy on the server (OneDrive copies in the background).
        try await p.rename(top.appending("a.txt"), to: top.appending("Docs").appending("b.txt"), replacing: false)
        let docs = try #require(s.fake.child("Docs"))
        #expect(s.fake.child("b.txt", in: docs.id)?.data == Data("a".utf8))
        try await p.clone(top.appending("Docs").appending("b.txt"), to: top.appending("c.txt"))
        #expect(s.fake.child("c.txt")?.data == Data("a".utf8))
        await #expect(throws: VFSError.alreadyExists(top.appending("c.txt"))) {
            try await p.clone(top.appending("Docs").appending("b.txt"), to: top.appending("c.txt"))
        }
        // Replacing moves the old file to the recycle bin.
        let old = try #require(s.fake.child("c.txt")).id
        await #expect(throws: VFSError.alreadyExists(top.appending("c.txt"))) {
            try await p.rename(top.appending("Docs").appending("b.txt"), to: top.appending("c.txt"), replacing: false)
        }
        try await p.rename(top.appending("Docs").appending("b.txt"), to: top.appending("c.txt"), replacing: true)
        #expect(s.fake.item(old)?.deleted == true)
        // A change of case only.
        try await p.rename(top.appending("c.txt"), to: top.appending("C.txt"), replacing: false)
        #expect(s.fake.child("C.txt") != nil)
        // A folder with something in it is not deleted; the recycle bin takes it whole.
        s.fake.put("keep.txt", in: docs.id, Data())
        await #expect(throws: VFSError.directoryNotEmpty(top.appending("Docs"))) { try await p.remove(top.appending("Docs")) }
        try await p.trash(top.appending("Docs"))
        #expect(s.fake.item(docs.id)?.deleted == true)
        #expect(try await names(s, top) == ["C.txt"])
        // Personal accounts have no permanent delete: the recycle bin.
        let last = try #require(s.fake.child("C.txt")).id
        try await p.remove(top.appending("C.txt"))
        #expect(s.fake.item(last)?.deleted == true && s.fake.state.withLock { $0.permanentDeletes } == 0)
        await #expect(throws: VFSError.permissionDenied(top)) { try await p.remove(top) }
    }

    @Test func workAccountsDeleteForGood() async throws {
        var id = ""
        let s = try await setUp(business: true) { id = $0.put("a.txt", Data("a".utf8)) }
        try await s.provider.remove(s.top.appending("a.txt"))
        #expect(s.fake.item(id) == nil && s.fake.state.withLock { $0.permanentDeletes } == 1)
    }

    @Test func datesAreKept() async throws {
        let s = try await setUp()
        let date = Date(timeIntervalSince1970: 1_600_000_000.25)
        for (name, size) in [("small.txt", 10), ("large.bin", 5 * mb)] {
            let src = try local(s, name, randomData(size))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: src.path)
            _ = try await engine(s.registry).transferFile(src, to: s.top.appending(name), mode: .copy, LocalProvider(), s.provider)
            let stored = try #require(s.fake.child(name))
            #expect(abs(stored.modified.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.002, "\(name)")
        }
        // A rename keeps the date.
        try await s.provider.rename(s.top.appending("small.txt"), to: s.top.appending("renamed.txt"), replacing: false)
        #expect(abs((s.fake.child("renamed.txt")?.modified.timeIntervalSince1970 ?? 0) - date.timeIntervalSince1970) < 0.002)
    }

    // MARK: Uploads

    @Test func smallAndLargeUploadsAreCheckedAndPartialFilesRenamed() async throws {
        let s = try await setUp()
        let small = try local(s, "small.bin", randomData(100_000))
        let large = try local(s, "large.bin", randomData(21 * mb + 77))
        let empty = try local(s, "empty.bin", Data())
        for (source, name) in [(small, "small.bin"), (large, "large.bin"), (empty, "empty.bin")] {
            _ = try await engine(s.registry).transferFile(source, to: s.top.appending(name), mode: .copy, LocalProvider(), s.provider)
            #expect(try s.fake.child(name)?.data == Data(contentsOf: URL(fileURLWithPath: source.path)))
        }
        // The large one went up in 10 MiB pieces plus the rest.
        #expect(s.fake.state.withLock { $0.chunks } == 3)
        #expect(s.fake.children().allSatisfy { !$0.name.hasPrefix(".basil-partial-") })
        // Plain mode with read-back verification.
        let other = try local(s, "other.bin", randomData(6 * mb))
        _ = try await engine(s.registry, secure: false, verify: true)
            .transferFile(other, to: s.top.appending("other.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(try s.fake.child("other.bin")?.data == Data(contentsOf: URL(fileURLWithPath: other.path)))
        // No token went to the upload or download addresses.
        #expect(s.fake.state.withLock { $0.leakedTokens } == 0)
    }

    @Test func anUploadClosedBeforeTheEndIsNeverStored() async throws {
        let s = try await setUp()
        let file = try await s.provider.createFile(s.top.appending("z.bin"))
        try await file.write(randomData(9 * mb), at: 0)
        await file.close()
        #expect(s.fake.child("z.bin") == nil)
        #expect(s.fake.state.withLock { $0.sessions.isEmpty })
        let spools = FileManager.default.temporaryDirectory.appendingPathComponent("Basil OneDrive uploads")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: spools.path)) ?? []).isEmpty)
        // Removing the never-stored file only forgets it.
        try await s.provider.remove(s.top.appending("z.bin"))
    }

    @Test func localSourceAppendedDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(2 * mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: s.top.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.child("a.bin")?.data == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(6 * mb))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(src, to: s.top.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.child("a.bin")?.data == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(7 * mb))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: s.top.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.child("a.bin")?.data == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    // MARK: Downloads

    func download(_ s: Setup, _ name: String, change: @escaping @Sendable () -> Void) async throws -> FileTransferResult {
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 1 { once { change() } }
        }
        let target = VFSPath.local(s.folder.appendingPathComponent(name).path)
        return try await copy.transferFile(s.top.appending(name), to: target, mode: .copy, s.provider, LocalProvider())
    }

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let original = randomData(3 * mb + 100)
        var id = ""
        let s = try await setUp { id = $0.put("r.bin", original) }
        let more = randomData(mb)
        let file = id
        let result = try await download(s, "r.bin") { s.fake.change(file, original + more) }
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("r.bin")) == original + more)
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let original = randomData(4 * mb)
        var id = ""
        let s = try await setUp { id = $0.put("r.bin", original) }
        let file = id
        let result = try await download(s, "r.bin") { s.fake.change(file, original.prefix(2 * mb + 5)) }
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("r.bin")) == original.prefix(2 * mb + 5))
    }

    @Test func remoteSourceRewrittenAtTheSameSizeAndTimeDuringDownload() async throws {
        var data = randomData(3 * mb)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var id = ""
        let s = try await setUp { id = $0.put("r.bin", data, modified: date) }
        data.replaceSubrange(100..<150, with: randomData(50))
        let changed = data
        let file = id
        let result = try await download(s, "r.bin") { s.fake.change(file, changed, modified: date) }
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("r.bin")) == changed)
        #expect(s.fake.state.withLock { $0.leakedTokens } == 0)
    }

    @Test func readsAtOffsets() async throws {
        let data = randomData(5 * mb + 3)
        let s = try await setUp { $0.put("w.bin", data) }
        let reader = try await s.provider.openForReading(s.top.appending("w.bin"), bypassCache: false)
        #expect(try await reader.read(at: Int64(4 * mb - 10), count: 20) == data.subdata(in: (4 * mb - 10)..<(4 * mb + 10)))
        #expect(try await reader.read(at: 5, count: 5) == data.subdata(in: 5..<10))
        #expect(try await reader.read(at: Int64(5 * mb), count: 100) == data.suffix(3))
        #expect(try await reader.read(at: Int64(data.count), count: 100).isEmpty)
        await reader.close()
    }

    @Test func linksAreTheItemsWebAddresses() async throws {
        let s = try await setUp { $0.put("a.txt", Data()) }
        let link = try await s.provider.sharedLink(for: s.top.appending("a.txt"))
        #expect(link.absoluteString.hasPrefix("https://onedrive.live.com/"))
    }
}
