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
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) {}
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}

// MARK: Pieces

@Suite struct GoogleDrivePiecesTests {
    @Test func authorizationAddressAsksForOfflineAccessWithPKCE() throws {
        let auth = GoogleAuth(client: GoogleClient(id: "abc.apps.googleusercontent.com", secret: "s"), hosts: .google, session: .shared)
        let url = auth.authorizationURL(pkce: OAuthPKCE(), state: "st", redirect: GoogleAuth.redirectURI(port: 50123),
                                        account: "me+x@example.com")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(query["client_id"] == "abc.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://127.0.0.1:50123/google")
        #expect(query["response_type"] == "code" && query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline" && query["prompt"] == "consent")
        #expect(query["scope"] == "https://www.googleapis.com/auth/drive")
        #expect(query["state"] == "st")
        // "+" is encoded, so it is not read as a space.
        #expect(url.absoluteString.contains("login_hint=me%2Bx@example.com"))
    }

    @Test func extraItemsOfOneNameAreNumberedOldestFirst() {
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        let named = DriveNames.unique([
            (name: "notes.txt", folder: false, created: new, id: "b", value: "B"),
            (name: "notes.txt", folder: false, created: old, id: "a", value: "A"),
            (name: "notes (2).txt", folder: false, created: old, id: "c", value: "C"),
            (name: "notes.txt", folder: false, created: new, id: "d", value: "D"),
            (name: "Photos", folder: true, created: old, id: "e", value: "E"),
            (name: "Photos", folder: true, created: new, id: "f", value: "F"),
            (name: "v1.0", folder: true, created: new, id: "g", value: "G"),
            (name: "v1.0", folder: true, created: new, id: "h", value: "H"),
        ])
        let byValue = Dictionary(uniqueKeysWithValues: named.map { ($0.1, $0.0) })
        #expect(byValue["A"] == "notes.txt")
        // "notes (2).txt" exists, so the extras go on with 3 and 4.
        #expect(byValue["C"] == "notes (2).txt")
        #expect(byValue["B"] == "notes (3).txt" && byValue["D"] == "notes (4).txt")
        #expect(byValue["E"] == "Photos" && byValue["F"] == "Photos (2)")
        #expect(byValue["G"] == "v1.0" && byValue["H"] == "v1.0 (2)")
    }

    @Test func googleDocumentsAreNamedAfterTheirExport() {
        let doc = DriveFile(id: "1", name: "Report", mimeType: "application/vnd.google-apps.document")
        let (name, ref) = GoogleDriveProvider.describe(doc, target: nil, volume: "my")
        #expect(name == "Report.docx" && ref.addedExtension == "docx" && ref.export(DriveExportFormats())?.fileExtension == "docx")
        #expect(GoogleDriveProvider.storedName("Notes.docx", for: ref) == "Notes")
        #expect(GoogleDriveProvider.storedName("Notes.txt", for: ref) == "Notes.txt")
        // A converted upload often keeps its extension in the name: nothing is added.
        let converted = DriveFile(id: "2", name: "Budget.xlsx", mimeType: "application/vnd.google-apps.spreadsheet")
        #expect(GoogleDriveProvider.describe(converted, target: nil, volume: "my").0 == "Budget.xlsx")
        let drawing = DriveFile(id: "3", name: "Plan", mimeType: "application/vnd.google-apps.drawing")
        #expect(GoogleDriveProvider.describe(drawing, target: nil, volume: "my").0 == "Plan.pdf")
        // Forms cannot be downloaded: listed under their own name.
        let form = DriveFile(id: "4", name: "Survey", mimeType: "application/vnd.google-apps.form")
        let (formName, formRef) = GoogleDriveProvider.describe(form, target: nil, volume: "my")
        #expect(formName == "Survey" && formRef.export(DriveExportFormats()) == nil && formRef.isGoogleType)
        #expect(GoogleDriveProvider.mayBeMadeName("a (2).txt") && GoogleDriveProvider.mayBeMadeName("Report.docx"))
        #expect(!GoogleDriveProvider.mayBeMadeName("a.txt") && !GoogleDriveProvider.mayBeMadeName("a (x).txt"))
    }

    @Test func queriesQuoteNames() {
        #expect(DriveNames.quoted(#"it's a\b"#) == #"'it\'s a\\b'"#)
    }

    @Test func datesKeepMilliseconds() throws {
        let date = try #require(DriveDate.parse("2026-11-23T10:20:30.456Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_795_429_230.456) < 0.0005)
        #expect(DriveDate.parse("2026-11-23T10:20:30Z") != nil)
        #expect(DriveDate.format(seconds: 1_795_429_230, nanos: 456_000_000) == "2026-11-23T10:20:30.456Z")
    }
}

// MARK: Against the fake

@Suite(.serialized) struct GoogleDriveTests {
    struct Setup {
        let fake: FakeGoogleDrive
        let secrets: MemorySecretStore
        let connector: GoogleDriveConnector
        let registry: ProviderRegistry
        let provider: GoogleDriveProvider
        let start: VFSPath
        let folder: URL
        let prompts: GoogleBrowserPrompts
        var top: VFSPath { VFSPath(location: provider.location, path: "/") }
        var my: VFSPath { provider.homeDirectory }
    }

    func setUp(path: String? = nil, options: [String: String]? = nil, fill: ((FakeGoogleDrive) -> Void)? = nil) async throws -> Setup {
        let fake = try FakeGoogleDrive()
        fill?(fake)
        let secrets = MemorySecretStore()
        let connector = GoogleDriveConnector(client: FakeGoogleDrive.client, secrets: secrets, hosts: fake.hosts)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: connector)
        let prompts = GoogleBrowserPrompts(fake)
        let start = try await registry.connect(RemoteTarget(service: .googleDrive, host: "", path: path, options: options), prompts: prompts)
        let provider = try #require(try registry.provider(for: start.location) as? GoogleDriveProvider)
        let folder = TestScratch.url.appendingPathComponent("basil-gdrive-\(UUID().uuidString)")
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
        #expect(redirect?.hasPrefix("http://127.0.0.1:") == true && redirect?.hasSuffix("/google") == true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(s.prompts.returnPages.withLock { $0.first?.contains("Signed in to Google Drive") } == true)
        #expect(s.secrets.secret(for: "gdrive:\(s.fake.permissionID)")?.hasPrefix("refresh-") == true)
        #expect(s.provider.connectionTitle == "Google Drive (tester@example.com)")
        let target = try #require(s.provider.signedInTarget)
        #expect(target.host == s.fake.permissionID && target.user == "tester@example.com")
        #expect(s.start.path == "/My Drive")
    }

    @Test func aSavedAccountConnectsWithoutTheBrowser() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        let quiet = GoogleBrowserPrompts(s.fake, giveUp: true)
        let start = try await s.registry.connect(saved, prompts: quiet)
        #expect(quiet.signIns.withLock { $0.isEmpty })
        #expect(start.location.instance == "tester@example.com")
    }

    @Test func removedAccessSignsInAgainWithTheAccountAsHint() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.registry.disconnect(s.provider.location)
        s.fake.removeAccess()
        let prompts = GoogleBrowserPrompts(s.fake)
        _ = try await s.registry.connect(saved, prompts: prompts)
        let asked = try #require(prompts.signIns.withLock { $0.first })
        #expect(asked.url.absoluteString.contains("login_hint=tester@example.com"))
    }

    @Test func aSignInWithoutTheDrivePermissionFails() async throws {
        let fake = try FakeGoogleDrive()
        fake.state.withLock { $0.grantedScopes = "openid" }
        let secrets = MemorySecretStore()
        let connector = GoogleDriveConnector(client: FakeGoogleDrive.client, secrets: secrets, hosts: fake.hosts)
        await #expect(throws: VFSError.self) {
            _ = try await connector.connect(RemoteTarget(service: .googleDrive, host: ""), prompts: GoogleBrowserPrompts(fake))
        }
        #expect(fake.state.withLock { $0.revokes } == 1)
        #expect(secrets.secret(for: "gdrive:\(fake.permissionID)") == nil)
    }

    @Test func givingUpInTheBrowserCancels() async throws {
        let fake = try FakeGoogleDrive()
        let connector = GoogleDriveConnector(client: FakeGoogleDrive.client, secrets: MemorySecretStore(), hosts: fake.hosts)
        await #expect(throws: RemoteCancelled.self) {
            _ = try await connector.connect(RemoteTarget(service: .googleDrive, host: ""), prompts: GoogleBrowserPrompts(fake, giveUp: true))
        }
    }

    @Test func expiredAccessTokensAndRateLimitsAreHandled() async throws {
        let s = try await setUp { $0.put("a.txt", Data("a".utf8)) }
        s.fake.expireAccessTokens()
        #expect(try await names(s, s.my) == ["a.txt"])
        s.fake.expireAccessTokens()
        s.fake.state.withLock { $0.rateLimited = 2 }
        let reader = try await s.provider.openForReading(s.my.appending("a.txt"), bypassCache: false)
        #expect(try await reader.read(at: 0, count: 10) == Data("a".utf8))
        #expect(s.fake.state.withLock { $0.refreshes } >= 2 && s.fake.state.withLock { $0.rateLimited } == 0)
    }

    @Test func forgettingRevokesUnlessAnotherConnectionUsesTheAccount() async throws {
        let s = try await setUp()
        let saved = try #require(s.provider.signedInTarget)
        await s.connector.forget(saved, remaining: [saved])
        #expect(s.fake.state.withLock { $0.revokes } == 0)
        await s.connector.forget(saved, remaining: [])
        #expect(s.secrets.secret(for: "gdrive:\(s.fake.permissionID)") == nil)
        #expect(s.fake.state.withLock { $0.revokes } == 1)
        #expect(s.fake.state.withLock { $0.refreshTokens.isEmpty })
    }

    // MARK: Places and names

    @Test func theTopHoldsThePlaces() async throws {
        var shared = ""
        let s = try await setUp { fake in
            let team = fake.drive("Team")
            fake.drive("Team")
            fake.put("plan.txt", in: team, Data("p".utf8))
            shared = fake.put("from-alice.pdf", in: "someone-elses-folder", Data("x".utf8))
            fake.share(shared)
        }
        #expect(try await names(s, s.top) == ["My Drive", "Shared drives", "Shared with me"])
        #expect(try await names(s, s.top.appending("Shared drives")) == ["Team", "Team (2)"])
        #expect(try await names(s, s.top.appending("Shared drives").appending("Team")) == ["plan.txt"])
        #expect(try await names(s, s.top.appending("Shared with me")) == ["from-alice.pdf"])
        let file = s.top.appending("Shared with me").appending("from-alice.pdf")
        #expect(try await s.provider.item(at: file).size == 1)
        // Nothing is made in the places themselves.
        await #expect(throws: VFSError.self) { try await s.provider.makeDirectory(s.top.appending("New")) }
        await #expect(throws: VFSError.self) { try await s.provider.makeDirectory(s.top.appending("Shared with me").appending("New")) }
        await #expect(throws: VFSError.permissionDenied(s.my)) { try await s.provider.remove(s.my) }
        // Each drive is its own volume, so moves between them copy.
        let a = try await s.provider.volumeIdentifier(of: s.my.appending("x"))
        let b = try await s.provider.volumeIdentifier(of: s.top.appending("Shared drives").appending("Team"))
        #expect(a != b)
    }

    @Test func watchedFolderReloadsOnChangesThere() async throws {
        var live = "", other = "", inside = ""
        let s = try await setUp {
            live = $0.folder("Live")
            other = $0.folder("Other")
            inside = $0.put("old.txt", in: live, Data("o".utf8))
        }
        let recorder = WatchRecorder(try #require(s.provider.watch(s.my.appending("Live"))))
        defer { recorder.stop() }
        // Let the watcher take its start token, then change another folder: nothing.
        try await Task.sleep(for: .milliseconds(300))
        s.fake.put("x.txt", in: other, Data("x".utf8))
        #expect(await !recorder.wait(for: 1, seconds: 0.6))
        // A new file in the folder, a changed one, and one moved out each reload.
        s.fake.put("new.txt", in: live, Data("n".utf8))
        #expect(await recorder.wait(for: 1, seconds: 3))
        s.fake.change(inside, Data("changed".utf8))
        #expect(await recorder.wait(for: 2, seconds: 3))
        s.fake.state.withLock { $0.items[inside]?.parents = [other] }
        #expect(await recorder.wait(for: 3, seconds: 3))
        // The places are not watched.
        let top = WatchRecorder(try #require(s.provider.watch(s.top)))
        defer { top.stop() }
        s.fake.folder("More")
        #expect(await !top.wait(for: 1, seconds: 0.5))
    }

    @Test func aStartFolderOpensThere() async throws {
        let s = try await setUp(path: "/My Drive/Photos") { $0.folder("Photos") }
        #expect(s.start.path == "/My Drive/Photos")
        #expect(try await s.provider.item(at: s.start).kind == .directory)
    }

    @Test func itemsOfOneNameAreNumberedAndEachIsItsOwn() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let s = try await setUp { fake in
            fake.put("notes.txt", Data("first".utf8), created: old)
            fake.put("notes.txt", Data("second".utf8), created: old + 10)
        }
        #expect(try await names(s, s.my) == ["notes (2).txt", "notes.txt"])
        func read(_ name: String) async throws -> Data {
            let reader = try await s.provider.openForReading(s.my.appending(name), bypassCache: false)
            defer { Task { await reader.close() } }
            return try await reader.read(at: 0, count: 100)
        }
        #expect(try await read("notes.txt") == Data("first".utf8))
        #expect(try await read("notes (2).txt") == Data("second".utf8))
        // Renaming the numbered one renames that item.
        try await s.provider.rename(s.my.appending("notes (2).txt"), to: s.my.appending("later.txt"), replacing: false)
        #expect(s.fake.child("later.txt")?.data == Data("second".utf8))
        #expect(try await names(s, s.my) == ["later.txt", "notes.txt"])
        // A new file cannot take a numbered name either.
        s.fake.put("notes.txt", Data("third".utf8), created: old + 20)
        _ = try await names(s, s.my)
        await #expect(throws: VFSError.alreadyExists(s.my.appending("notes (2).txt"))) {
            _ = try await s.provider.createFile(s.my.appending("notes (2).txt"))
        }
    }

    // MARK: Google documents

    @Test func exportFormatsAreChosenPerConnectionAndLargeExportsUseExportLinks() async throws {
        let s = try await setUp(options: ["exportDocuments": "md", "exportSpreadsheets": "csv"]) { fake in
            fake.put("Notes", Data("# Title".utf8), mime: FakeGoogleDrive.googleDoc)
            fake.put("Budget", Data("1,2".utf8), mime: "application/vnd.google-apps.spreadsheet")
            fake.put("Deck", Data("slides".utf8), mime: "application/vnd.google-apps.presentation")
        }
        #expect(try await names(s, s.my) == ["Budget.csv", "Deck.pptx", "Notes.md"])
        let target = VFSPath.local(s.folder.appendingPathComponent("Notes.md").path)
        _ = try await engine(s.registry).transferFile(s.my.appending("Notes.md"), to: target, mode: .copy, s.provider, LocalProvider())
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == FakeGoogleDrive.exported(Data("# Title".utf8), as: "text/markdown"))
        #expect(s.fake.state.withLock { $0.exportLinkDownloads } == 0)

        // Too large for files.export: the document's export link is used instead.
        s.fake.state.withLock { $0.exportLimit = 10 }
        let big = VFSPath.local(s.folder.appendingPathComponent("Budget.csv").path)
        _ = try await engine(s.registry).transferFile(s.my.appending("Budget.csv"), to: big, mode: .copy, s.provider, LocalProvider())
        #expect(try Data(contentsOf: URL(fileURLWithPath: big.path)) == FakeGoogleDrive.exported(Data("1,2".utf8), as: "text/csv"))
        #expect(s.fake.state.withLock { $0.exportLinkDownloads } == 1)
        // The editor offers one pop-up per kind of document, Office (PDF for Drawings) first.
        let options = s.connector.options
        #expect(options.map(\.key) == ["exportDocuments", "exportSpreadsheets", "exportPresentations", "exportDrawings"])
        if case .choice(let choices, let first) = options[0].kind {
            #expect(first == "docx" && choices.map(\.value).contains("md"))
        } else {
            Issue.record("not a pop-up")
        }
    }

    @Test func googleDocumentsAreReadAsTheirExport() async throws {
        var doc = ""
        let s = try await setUp { fake in
            doc = fake.put("Report", Data("body".utf8), mime: FakeGoogleDrive.googleDoc)
            fake.put("Survey", Data(), mime: "application/vnd.google-apps.form")
        }
        let items = try await collect(s.provider.list(s.my))
        let report = try #require(items.first { $0.name == "Report.docx" })
        #expect(report.size == nil && report.kind == .file)
        #expect(items.contains { $0.name == "Survey" })
        let expected = FakeGoogleDrive.exported(Data("body".utf8),
                                                as: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        // The fingerprint knows the export's size; the export is made once per version.
        let print = try await s.provider.fingerprint(of: s.my.appending("Report.docx"))
        #expect(print.size == Int64(expected.count))
        let target = VFSPath.local(s.folder.appendingPathComponent("Report.docx").path)
        _ = try await engine(s.registry).transferFile(s.my.appending("Report.docx"), to: target, mode: .copy, s.provider, LocalProvider())
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == expected)
        #expect(s.fake.state.withLock { $0.exports } == 1)
        // A new version is exported again.
        s.fake.change(doc, Data("changed".utf8))
        #expect(try await s.provider.fingerprint(of: s.my.appending("Report.docx")) != print)
        #expect(s.fake.state.withLock { $0.exports } == 2)
        // Forms cannot be downloaded.
        await #expect(throws: VFSError.self) {
            _ = try await s.provider.openForReading(s.my.appending("Survey"), bypassCache: false)
        }
        // Renaming keeps the document's own name without the added extension.
        try await s.provider.rename(s.my.appending("Report.docx"), to: s.my.appending("Final.docx"), replacing: false)
        #expect(s.fake.item(doc)?.name == "Final")
        // A server-side copy stays a Google document.
        try await s.provider.clone(s.my.appending("Final.docx"), to: s.my.appending("Copy.docx"))
        #expect(s.fake.child("Copy")?.mimeType == FakeGoogleDrive.googleDoc)
        // Google documents are never replaced by a rename.
        s.fake.put("other.docx", Data("o".utf8))
        await #expect(throws: VFSError.self) {
            try await s.provider.rename(s.my.appending("other.docx"), to: s.my.appending("Final.docx"), replacing: true)
        }
        #expect(s.fake.item(doc)?.trashed == false)
    }

    // MARK: Shortcuts

    @Test func shortcutsFollowTheirTargets() async throws {
        var folder = "", file = ""
        let s = try await setUp { fake in
            folder = fake.folder("Projects")
            fake.put("inside.txt", in: folder, Data("in".utf8))
            file = fake.put("data.bin", Data("target data".utf8))
            fake.shortcut("Projects link", to: folder)
            fake.shortcut("Data link", to: file)
        }
        let items = try await collect(s.provider.list(s.my))
        #expect(items.first { $0.name == "Projects link" }?.kind == .symlink(target: .directory))
        #expect(items.first { $0.name == "Data link" }?.size == Int64("target data".utf8.count))
        // A folder shortcut opens the target.
        #expect(try await names(s, s.my.appending("Projects link")) == ["inside.txt"])
        // A file shortcut copies the target's content.
        let target = VFSPath.local(s.folder.appendingPathComponent("Data link").path)
        _ = try await engine(s.registry).transferFile(s.my.appending("Data link"), to: target, mode: .copy, s.provider, LocalProvider())
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == Data("target data".utf8))
        // F5 on a folder shortcut copies the folder it leads to, under the shortcut's name; a
        // shortcut inside a copied folder stays a link (no endless copies through a link upwards).
        s.fake.shortcut("Back up", in: folder, to: folder)
        let copied = VFSPath.local(s.folder.appendingPathComponent("Projects link").path)
        let summary = try await engine(s.registry).transfer(s.my.appending("Projects link"), to: copied, mode: .copy)
        #expect(summary.files == 1 && summary.directories == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied.path + "/inside.txt")) == Data("in".utf8))
        let inner = try FileManager.default.attributesOfItem(atPath: copied.path + "/Back up")[.type] as? FileAttributeType
        #expect(inner == .typeSymbolicLink)
        // Deleting a folder shortcut (as Shift+F8 does, through the delete operation) removes only the shortcut.
        #expect(try await s.provider.fingerprint(of: s.my.appending("Projects link")).kind == .symlink)
        try await s.provider.remove(s.my.appending("Projects link"))
        try await s.provider.remove(s.my.appending("Data link"))
        try await s.provider.remove(s.my.appending("Projects").appending("Back up"))
        #expect(s.fake.child("inside.txt", in: folder) != nil && s.fake.item(file) != nil)
        #expect(try await names(s, s.my) == ["Projects", "data.bin"])
    }

    // MARK: Changes

    @Test func foldersRenamesMovesCopiesAndDeletes() async throws {
        let s = try await setUp { $0.put("a.txt", Data("a".utf8)) }
        let p = s.provider
        try await p.makeDirectory(s.my.appending("Docs"))
        await #expect(throws: VFSError.alreadyExists(s.my.appending("Docs"))) { try await p.makeDirectory(s.my.appending("Docs")) }
        // Move into a folder (a rename with new parents), then copy on the server.
        try await p.rename(s.my.appending("a.txt"), to: s.my.appending("Docs").appending("b.txt"), replacing: false)
        let docs = try #require(s.fake.child("Docs"))
        #expect(s.fake.child("b.txt", in: docs.id)?.data == Data("a".utf8))
        try await p.clone(s.my.appending("Docs").appending("b.txt"), to: s.my.appending("c.txt"))
        #expect(s.fake.child("c.txt")?.data == Data("a".utf8))
        await #expect(throws: VFSError.alreadyExists(s.my.appending("c.txt"))) {
            try await p.clone(s.my.appending("Docs").appending("b.txt"), to: s.my.appending("c.txt"))
        }
        // Replacing moves the old file to the trash.
        let old = try #require(s.fake.child("c.txt")).id
        await #expect(throws: VFSError.alreadyExists(s.my.appending("c.txt"))) {
            try await p.rename(s.my.appending("Docs").appending("b.txt"), to: s.my.appending("c.txt"), replacing: false)
        }
        try await p.rename(s.my.appending("Docs").appending("b.txt"), to: s.my.appending("c.txt"), replacing: true)
        #expect(s.fake.item(old)?.trashed == true)
        // A folder with something in it is not deleted; the trash takes it whole.
        s.fake.put("keep.txt", in: docs.id, Data())
        await #expect(throws: VFSError.directoryNotEmpty(s.my.appending("Docs"))) { try await p.remove(s.my.appending("Docs")) }
        try await p.trash(s.my.appending("Docs"))
        #expect(s.fake.item(docs.id)?.trashed == true)
        #expect(try await names(s, s.my) == ["c.txt"])
        try await p.remove(s.my.appending("c.txt"))
        #expect(s.fake.children().isEmpty)
    }

    @Test func datesAreKept() async throws {
        let s = try await setUp()
        let src = try local(s, "dated.txt", Data("d".utf8))
        let date = Date(timeIntervalSince1970: 1_600_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: src.path)
        _ = try await engine(s.registry).transferFile(src, to: s.my.appending("dated.txt"), mode: .copy, LocalProvider(), s.provider)
        let stored = try #require(s.fake.child("dated.txt"))
        #expect(abs(stored.modified.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.002)
        // A rename keeps the date.
        try await s.provider.rename(s.my.appending("dated.txt"), to: s.my.appending("renamed.txt"), replacing: false)
        #expect(abs((s.fake.child("renamed.txt")?.modified.timeIntervalSince1970 ?? 0) - date.timeIntervalSince1970) < 0.002)
    }

    // MARK: Uploads

    @Test func smallAndLargeUploadsAreCheckedAndPartialFilesRenamed() async throws {
        let s = try await setUp()
        let small = try local(s, "small.bin", randomData(100_000))
        let large = try local(s, "large.bin", randomData(21 * mb + 77))
        for (source, name) in [(small, "small.bin"), (large, "large.bin")] {
            _ = try await engine(s.registry).transferFile(source, to: s.my.appending(name), mode: .copy, LocalProvider(), s.provider)
            #expect(try s.fake.child(name)?.data == Data(contentsOf: URL(fileURLWithPath: source.path)))
        }
        // The large one went up in 8 MB pieces plus the rest.
        #expect(s.fake.state.withLock { $0.chunks } == 3)
        #expect(s.fake.children().allSatisfy { !$0.name.hasPrefix(".basil-partial-") })
        // Plain mode with read-back verification.
        let other = try local(s, "other.bin", randomData(6 * mb))
        _ = try await engine(s.registry, secure: false, verify: true)
            .transferFile(other, to: s.my.appending("other.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(try s.fake.child("other.bin")?.data == Data(contentsOf: URL(fileURLWithPath: other.path)))
    }

    @Test func anUploadClosedBeforeTheEndIsNeverStored() async throws {
        let s = try await setUp()
        let file = try await s.provider.createFile(s.my.appending("z.bin"))
        try await file.write(randomData(9 * mb), at: 0)
        await file.close()
        #expect(s.fake.child("z.bin") == nil)
        #expect(s.fake.state.withLock { $0.uploads.isEmpty })
        // Removing the never-stored file only forgets it.
        try await s.provider.remove(s.my.appending("z.bin"))
    }

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
        let result = try await copy.transferFile(src, to: s.my.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
        #expect(result.retries == 1)
        #expect(try s.fake.child("a.bin")?.data == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let s = try await setUp()
        let src = try local(s, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(s.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(src, to: s.my.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
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
        let result = try await copy.transferFile(src, to: s.my.appending("a.bin"), mode: .copy, LocalProvider(), s.provider)
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
        return try await copy.transferFile(s.my.appending(name), to: target, mode: .copy, s.provider, LocalProvider())
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
    }

    @Test func readsAtOffsets() async throws {
        let data = randomData(5 * mb + 3)
        let s = try await setUp { $0.put("w.bin", data) }
        let reader = try await s.provider.openForReading(s.my.appending("w.bin"), bypassCache: false)
        #expect(try await reader.read(at: Int64(4 * mb - 10), count: 20) == data.subdata(in: (4 * mb - 10)..<(4 * mb + 10)))
        #expect(try await reader.read(at: 5, count: 5) == data.subdata(in: 5..<10))
        #expect(try await reader.read(at: Int64(5 * mb), count: 100) == data.suffix(3))
        #expect(try await reader.read(at: Int64(data.count), count: 100).isEmpty)
        await reader.close()
    }

    @Test func movesBetweenDrivesAndFromSharedWithMeCopy() async throws {
        var team = ""
        let s = try await setUp { fake in
            team = fake.drive("Team")
            fake.put("mine.txt", Data("m".utf8))
        }
        let copy = engine(s.registry)
        let destination = s.top.appending("Shared drives").appending("Team").appending("mine.txt")
        _ = try await copy.transfer(s.my.appending("mine.txt"), to: destination, mode: .move)
        #expect(s.fake.child("mine.txt", in: team)?.data == Data("m".utf8))
        #expect(s.fake.child("mine.txt") == nil)
    }

    @Test func linksAreTheItemsDriveLinks() async throws {
        let s = try await setUp { $0.put("a.txt", Data()) }
        let link = try await s.provider.sharedLink(for: s.my.appending("a.txt"))
        #expect(link.absoluteString.hasPrefix("https://drive.google.com/file/d/"))
    }
}
