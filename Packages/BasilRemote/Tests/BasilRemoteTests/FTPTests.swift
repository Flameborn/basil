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

/// The FTP client against pure-ftpd: plain FTP, FTPS explicit and implicit, passive and active
/// mode, MLSD and LIST servers, certificates, and the copy engine with changing sources.
@Suite(.serialized) struct FTPTests {
    let server: FTPTestServer
    init() throws { server = try #require(FTPTestServer.shared, "pure-ftpd could not be started") }

    struct Connection {
        let registry: ProviderRegistry
        let ftp: FTPProvider
        let root: VFSPath
        let prompts: FTPPrompts
        func close() async { await registry.disconnect(root.location) }
    }

    func connect(_ box: RemoteSandbox, _ kind: FTPConnector.Kind = .explicitTLS, options: [String: String]? = nil,
                 ignoreModernListing: Bool = false, prompts: FTPPrompts? = nil) async throws -> Connection {
        try box.prepare()
        let prompts = prompts ?? FTPPrompts(secrets: [server.password])
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: server.connector(kind, trustFile: box.folder.appendingPathComponent("trusted"),
                                                      ignoreModernListing: ignoreModernListing))
        let start = try await registry.connect(server.target(kind, path: box.path, options: options), prompts: prompts)
        let ftp = try #require(try registry.provider(for: start.location) as? FTPProvider)
        return Connection(registry: registry, ftp: ftp, root: start, prompts: prompts)
    }

    // MARK: Connecting

    @Test(arguments: [FTPConnector.Kind.plain, .explicitTLS, .implicitTLS])
    func connectsAndLists(_ kind: FTPConnector.Kind) async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box, kind)
        try Data("hi".utf8).write(to: URL(fileURLWithPath: box.path + "/a.txt"))
        var items: [FileItem] = []
        for try await batch in c.ftp.list(c.root) { items += batch }
        #expect(items.map(\.name) == ["a.txt"])
        #expect(items.first?.size == 2)
        #expect(c.root.path == box.path)
        let requests = c.prompts.state.withLock { $0.secretRequests }
        #expect(requests.first?.keychainKey == "ftp:\(server.user)@127.0.0.1:\(kind == .implicitTLS ? server.implicitPort : server.port)")
        #expect(c.prompts.state.withLock { $0.worked } == 1)
        let questions = c.prompts.state.withLock { $0.certificateQuestions }
        #expect(questions.count == (kind == .plain ? 0 : 1))
        await c.close()
    }

    @Test func untrustedCertificateIsAskedAndRemembered() async throws {
        let box = try RemoteSandbox()
        let first = FTPPrompts(certificate: .trustAndRemember, secrets: [server.password])
        let c = try await connect(box, prompts: first)
        let question = try #require(first.state.withLock { $0.certificateQuestions.first })
        guard case .untrusted = question.reason else { Issue.record("expected an untrusted certificate"); return }
        #expect(question.subject == "localhost")
        #expect(question.host == "127.0.0.1:\(server.port)")
        #expect(question.fingerprint.hasPrefix("SHA256:"))
        #expect(question.validity.hasPrefix("valid until"))
        await c.close()

        // Remembered: no question the second time.
        let again = FTPPrompts(certificate: .cancel, secrets: [server.password])
        let d = try await connect(box, prompts: again)
        #expect(again.state.withLock { $0.certificateQuestions.isEmpty })
        await d.close()
    }

    @Test func changedCertificateIsAskedAndCancelStops() async throws {
        let box = try RemoteSandbox()
        try FTPTrust(file: box.folder.appendingPathComponent("trusted")).remember(Data(repeating: 7, count: 32), for: "127.0.0.1:\(server.port)")
        let prompts = FTPPrompts(certificate: .cancel, secrets: [server.password])
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(box, prompts: prompts) }
        let reason = prompts.state.withLock { $0.certificateQuestions.first?.reason }
        guard case .changed = reason else { Issue.record("expected a changed certificate"); return }
        #expect(prompts.state.withLock { $0.secretRequests.isEmpty })
    }

    @Test func wrongPasswordIsAskedAgain() async throws {
        let box = try RemoteSandbox()
        let prompts = FTPPrompts(secrets: ["wrong", server.password])
        let c = try await connect(box, prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.map(\.retry) } == [false, true])
        await c.close()
    }

    @Test func cancelledPasswordStops() async throws {
        let box = try RemoteSandbox()
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(box, prompts: FTPPrompts(secrets: [nil])) }
    }

    @Test func emptyUserIsAnonymous() {
        let connector = FTPConnector(.plain, trustFile: URL(fileURLWithPath: "/nonexistent"))
        let endpoint = connector.endpoint(for: RemoteTarget(service: .ftp, host: "example.com"))
        #expect(endpoint.user == "anonymous" && endpoint.anonymous)
        #expect(endpoint.account == "anonymous@example.com")
        let forced = connector.endpoint(for: RemoteTarget(service: .ftp, host: "h", user: "me", options: ["anonymous": "true"]))
        #expect(forced.anonymous)
        let named = connector.endpoint(for: RemoteTarget(service: .ftp, host: "h", port: 2121, user: "me", options: ["encoding": "windows-1252", "activeMode": "true"]))
        #expect(!named.anonymous && named.encoding == .windows1252 && named.activeMode && named.account == "me@h:2121")
    }

    // MARK: Files

    /// Every file operation, on MLSD and on LIST, passive and active, plain and TLS.
    @Test(arguments: [(FTPConnector.Kind.explicitTLS, false, false), (.explicitTLS, true, false),
                      (.plain, false, true), (.implicitTLS, true, true)])
    func listsAndChangesFiles(_ kind: FTPConnector.Kind, _ listOnly: Bool, _ active: Bool) async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box, kind, options: active ? ["activeMode": "true", "listHidden": "true"] : ["listHidden": "true"],
                                  ignoreModernListing: listOnly)
        defer { Task { await c.close() } }
        let ftp = c.ftp, root = c.root
        let local = URL(fileURLWithPath: box.path)
        try Data("hello".utf8).write(to: local.appendingPathComponent("a b.txt"))
        try Data().write(to: local.appendingPathComponent(".hidden"))
        try Data("x".utf8).write(to: local.appendingPathComponent("Gr\u{fc}\u{df}e.txt"))
        try FileManager.default.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)

        var items: [FileItem] = []
        for try await batch in ftp.list(root) { items += batch }
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a b.txt", ".hidden", "Gr\u{fc}\u{df}e.txt", "sub"])
        #expect(byName["a b.txt"]?.size == 5 && byName["a b.txt"]?.kind == .file)
        #expect(byName[".hidden"]?.isHidden == true)
        #expect(byName["sub"]?.kind == .directory)

        // Write a partial file, rename it into place, read it back.
        let partial = root.appending(".basil-partial-x")
        let file = try await ftp.createFile(partial)
        try await file.write(Data("01234".utf8), at: 0)
        try await file.write(Data("56789".utf8), at: 5)
        await #expect(throws: VFSError.self) { try await file.write(Data("A".utf8), at: 2) }
        try await file.synchronize()
        let warnings = try await file.apply(FileMetadata(permissions: 0o640, modified: timespec(tv_sec: 1_000_000_000, tv_nsec: 0)))
        #expect(warnings.isEmpty)
        await file.close()
        await #expect(throws: VFSError.alreadyExists(partial)) { _ = try await ftp.createFile(partial) }
        await #expect(throws: VFSError.alreadyExists(root.appending("a b.txt"))) {
            try await ftp.rename(partial, to: root.appending("a b.txt"), replacing: false)
        }
        try await ftp.rename(partial, to: root.appending("a b.txt"), replacing: true)
        #expect(try Data(contentsOf: local.appendingPathComponent("a b.txt")) == Data("0123456789".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: local.appendingPathComponent("a b.txt").path)
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_000_000_000))
        let item = try await ftp.item(at: root.appending("a b.txt"))
        #expect(item.size == 10)
        if !listOnly {
            #expect(item.modified == Date(timeIntervalSince1970: 1_000_000_000))
            #expect(item.permissions == 0o640)
        }
        let fingerprint = try await ftp.fingerprint(of: root.appending("a b.txt"))
        #expect(fingerprint.size == 10 && fingerprint.kind == .file)
        let reader = try await ftp.openForReading(root.appending("a b.txt"), bypassCache: false)
        #expect(try await reader.read(at: 0, count: 4) == Data("0123".utf8))
        #expect(try await reader.read(at: 4, count: 100) == Data("456789".utf8))
        #expect(try await reader.read(at: 10, count: 1).isEmpty)
        #expect(try await reader.read(at: 7, count: 2) == Data("78".utf8))
        await reader.close()
        // An empty file.
        let empty = try await ftp.createFile(root.appending("empty"))
        await empty.close()
        #expect(try Data(contentsOf: local.appendingPathComponent("empty")).isEmpty)

        // Folders and removal.
        try await ftp.makeDirectory(root.appending("new"))
        await #expect(throws: VFSError.alreadyExists(root.appending("new"))) { try await ftp.makeDirectory(root.appending("new")) }
        try Data().write(to: local.appendingPathComponent("new/in"))
        await #expect(throws: VFSError.directoryNotEmpty(root.appending("new"))) { try await ftp.remove(root.appending("new")) }
        try await ftp.remove(root.appending("new/in"))
        try await ftp.remove(root.appending("new"))
        await #expect(throws: VFSError.notFound(root.appending("new"))) { _ = try await ftp.item(at: root.appending("new")) }
        await #expect(throws: VFSError.notADirectory(root.appending("empty"))) {
            for try await _ in ftp.list(root.appending("empty")) {}
        }
        await #expect(throws: VFSError.notFound(root.appending("gone"))) {
            for try await _ in ftp.list(root.appending("gone")) {}
        }
        await #expect(throws: VFSError.self) { _ = try await ftp.item(at: root.appending("bad\r\nDELE x")) }
    }

    @Test func pooledSessionsServeAListingDuringATransfer() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let upload = try await c.ftp.createFile(c.root.appending("big"))
        try await upload.write(randomData(mb), at: 0)
        // The first session is busy with STOR; listing opens a second one.
        var names: [String] = []
        for try await batch in c.ftp.list(c.root) { names += batch.map(\.name) }
        #expect(names.contains("big"))
        try await upload.synchronize()
        await upload.close()
    }

    @Test func droppedIdleSessionIsReplaced() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let session = try await c.ftp.pool.acquire()
        try await session.run { try session.send("QUIT"); _ = try session.readReply() }
        c.ftp.pool.release(session)
        _ = try await c.ftp.item(at: c.root)
    }

    // MARK: Copy engine

    func engine(_ registry: ProviderRegistry, afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> SecureCopyEngine {
        SecureCopyEngine(registry: registry, options: SecureCopyOptions(retryDelay: .milliseconds(1), secure: true),
                         monitor: Monitor(), hooks: EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.rename, .clone, .stream]))
    }

    func localFile(_ box: RemoteSandbox, _ name: String, _ data: Data) throws -> VFSPath {
        let url = box.folder.appendingPathComponent(name)
        try data.write(to: url)
        return .local(url.path)
    }

    @Test func copiesATreeUpAndDownAndOnTheServer() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let tree = box.folder.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let big = randomData(3 * mb + 77)
        try big.write(to: tree.appendingPathComponent("inner/big.bin"))
        try Data("x".utf8).write(to: tree.appendingPathComponent("small.txt"))

        let up = try await engine(c.registry).transfer(.local(tree.path), to: c.root.appending("tree"), mode: .copy)
        #expect(up.failed.isEmpty)
        let served = URL(fileURLWithPath: box.path).appendingPathComponent("tree")
        #expect(try Data(contentsOf: served.appendingPathComponent("inner/big.bin")) == big)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: served.path).contains { $0.hasPrefix(".basil-partial-") })

        // Server to server: one session reads while another writes.
        _ = try await engine(c.registry).transfer(c.root.appending("tree"), to: c.root.appending("copy"), mode: .copy)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path + "/copy/inner/big.bin")) == big)

        let back = box.folder.appendingPathComponent("back")
        _ = try await engine(c.registry).transfer(c.root.appending("tree"), to: .local(back.path), mode: .move)
        #expect(try Data(contentsOf: back.appendingPathComponent("inner/big.bin")) == big)
        #expect(!FileManager.default.fileExists(atPath: served.path))
    }

    @Test func moveOnTheServerRenames() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        try Data("m".utf8).write(to: URL(fileURLWithPath: box.path).appendingPathComponent("m.txt"))
        try await c.ftp.makeDirectory(c.root.appending("to"))
        let result = try await engine(c.registry).transferFile(c.root.appending("m.txt"), to: c.root.appending("to/m.txt"),
                                                               mode: .move, c.ftp, c.ftp)
        #expect(result.strategy == .rename)
        #expect(FileManager.default.fileExists(atPath: box.path + "/to/m.txt"))
    }

    // A local source changing during an upload: FTP cannot write at offsets, so the partial file
    // is written again from the start.

    @Test func localSourceAppendedDuringUpload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let src = try localFile(box, "a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: c.root.appending("a.bin"), mode: .copy, LocalProvider(), c.ftp)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin")) == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let src = try localFile(box, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(src, to: c.root.appending("a.bin"), mode: .copy, LocalProvider(), c.ftp)
        #expect(result.retries == 1)
        let copied = try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin"))
        let original = try Data(contentsOf: URL(fileURLWithPath: src.path))
        #expect(copied.count == mb + 1000 && copied == original)
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let src = try localFile(box, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: c.root.appending("a.bin"), mode: .copy, LocalProvider(), c.ftp)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin")) == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    // A remote source changing during a download. MLSD gives size and whole-second times, so a
    // change is seen when the size changes or a second has passed.

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(3 * mb + 100).write(to: served)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: served)
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb)); try! h.close()
                }
            }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(c.root.appending("r.bin"), to: target, mode: .copy, c.ftp, LocalProvider())
        #expect(result.retries >= 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == Data(contentsOf: served))
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(4 * mb).write(to: served)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(served.path, off_t(2 * mb + 5)) } }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(c.root.appending("r.bin"), to: target, mode: .copy, c.ftp, LocalProvider())
        #expect(result.retries >= 1)
        let copied = try Data(contentsOf: URL(fileURLWithPath: target.path))
        let original = try Data(contentsOf: served)
        #expect(copied.count == 2 * mb + 5 && copied == original)
    }

    @Test func remoteSourceRewrittenAfterASecondDuringDownload() async throws {
        let box = try RemoteSandbox()
        let c = try await connect(box)
        defer { Task { await c.close() } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(3 * mb).write(to: served)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: served.path)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: served)
                    try! h.seek(toOffset: 100); try! h.write(contentsOf: randomData(50)); try! h.close()
                }
            }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(c.root.appending("r.bin"), to: target, mode: .copy, c.ftp, LocalProvider())
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == Data(contentsOf: served))
    }
}

/// The listing parsers, on lines real servers send.
@Suite struct FTPListingTests {
    let now = FTPListing.timestamp("20261122120000")!

    @Test func mlsdFacts() {
        let file = FTPListing.mlsd("type=file;size=6;modify=20261122173014.250;UNIX.mode=0644; a b.txt")
        #expect(file == FTPEntry(name: "a b.txt", kind: .file, size: 6,
                                 modified: FTPListing.timestamp("20261122173014")! + 0.25, permissions: 0o644, preciseTime: true))
        #expect(FTPListing.mlsd("type=dir;modify=20261122173014; sub")?.kind == .directory)
        #expect(FTPListing.mlsd("type=cdir;modify=20261122173014; .") == nil)
        #expect(FTPListing.mlsd("type=OS.unix=slink:/etc/hosts; h")?.kind == .symlink("/etc/hosts"))
    }

    @Test func unixList() {
        let file = FTPListing.list("-rw-r--r--   1 user  group      1234 Nov 20 10:05 my file.txt", now: now)
        #expect(file?.name == "my file.txt" && file?.size == 1234 && file?.permissions == 0o644)
        #expect(file?.modified == FTPListing.timestamp("20261120100500"))
        // A date "in the future" is last year's.
        #expect(FTPListing.list("-rw-r--r-- 1 u g 1 Dec 24 10:05 x", now: now)?.modified == FTPListing.timestamp("20251224100500"))
        #expect(FTPListing.list("drwxr-xr-x 2 u g 4096 Jan  3  2024 old", now: now)?.modified == FTPListing.timestamp("20240103000000"))
        #expect(FTPListing.list("lrwxrwxrwx 1 u g 4 Nov 22 2025 ln -> a b", now: now)?.kind == .symlink("a b"))
        // No group column.
        #expect(FTPListing.list("-rwxr-sr-t 1 owner 77 Nov 1 09:00 g", now: now)?.permissions == 0o3755)
        #expect(FTPListing.list("total 12", now: now) == nil)
        #expect(FTPListing.list("drwxr-xr-x 2 u g 4096 Nov 20 10:05 .", now: now) == nil)
    }

    @Test func dosList() {
        let dir = FTPListing.list("11-22-26  10:00AM       <DIR>          Program Files")
        #expect(dir?.name == "Program Files" && dir?.kind == .directory)
        #expect(dir?.modified == FTPListing.timestamp("20261122100000"))
        let file = FTPListing.list("2026-11-22  12:30PM            42 notes.txt")
        #expect(file?.size == 42 && file?.modified == FTPListing.timestamp("20261122123000"))
        #expect(FTPListing.list("01-02-99  12:15AM  5 x")?.modified == FTPListing.timestamp("19990102001500"))
    }

    @Test func passiveReplies() {
        #expect(FTPSession.epsvPort("Entering Extended Passive Mode (|||6446|)") == 6446)
        #expect(FTPSession.pasvAddress("Entering Passive Mode (192,168,1,2,195,149).")! == ("192.168.1.2", 50069))
        // A private address from a public server: the control connection's address instead.
        #expect(FTPSession.passiveHost(reply: "10.0.0.5", peer: "203.0.113.9") == "203.0.113.9")
        #expect(FTPSession.passiveHost(reply: "10.0.0.5", peer: "10.0.0.1") == "10.0.0.5")
        #expect(FTPSession.passiveHost(reply: "198.51.100.4", peer: "203.0.113.9") == "198.51.100.4")
    }

    @Test func encodings() {
        #expect(FTPEncoding.windows1252.decode(Array("caf\u{e9}".data(using: .windowsCP1252)!)) == "caf\u{e9}")
        #expect(FTPEncoding.utf8.decode([0x63, 0x61, 0x66, 0xE9]) == "caf\u{e9}")
        #expect(FTPEncoding.windows1252.encode("\u{4e2d}") == nil)
    }

    @Test func addressWithPasswordDropsIt() {
        let target = RemoteTarget.parse("ftp://me:secret@example.com:2121/pub", defaultService: .sftp)
        #expect(target?.service == .ftp && target?.user == "me" && target?.port == 2121 && target?.path == "/pub")
    }
}
