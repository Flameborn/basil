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

/// Runs a body once (engine hooks fire on every chunk).
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

@Suite(.serialized) struct SFTPTests {
    let server: TestServer
    init() throws { server = try #require(TestServer.shared, "sshd could not be started") }

    /// A connected provider with the work folder, trusting the server already.
    func connect(_ box: RemoteSandbox, auth: RemoteTarget.Authentication = .keyFile(""), agent: Bool = false,
                 prompts: TestPrompts = TestPrompts()) async throws -> (ProviderRegistry, SFTPProvider, VFSPath) {
        try box.prepare()
        try box.trustServer(server)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: server.connector(knownHosts: box.knownHosts, agent: agent))
        let start = try await registry.connect(server.target(auth, path: box.path), prompts: prompts)
        let provider = try #require(try registry.provider(for: start.location) as? SFTPProvider)
        return (registry, provider, start)
    }

    // MARK: Host keys

    @Test func unknownHostIsAskedAndRemembered() async throws {
        let box = try RemoteSandbox()
        try box.prepare()
        let registry = ProviderRegistry()
        registry.register(connector: server.connector(knownHosts: box.knownHosts))
        let prompts = TestPrompts(hostKey: .trustAndRemember)
        let start = try await registry.connect(server.target(path: box.path), prompts: prompts)
        let question = try #require(prompts.state.withLock { $0.hostKeyQuestions.first })
        #expect(question.reason == .unknown)
        #expect(question.host == "[127.0.0.1]:\(server.port)")
        #expect(question.keyType == "ED25519")
        #expect(question.fingerprint == KnownHosts.fingerprint(of: server.hostKeyBlob))
        #expect(start.path == box.path)
        #expect(KnownHosts(file: box.knownHosts).check(host: question.host, key: server.hostKeyBlob) == .known)
        await registry.disconnect(start.location)

        // Known now: no question the second time.
        let again = TestPrompts(hostKey: .cancel)
        let second = try await registry.connect(server.target(path: box.path), prompts: again)
        #expect(again.state.withLock { $0.hostKeyQuestions.isEmpty })
        await registry.disconnect(second.location)
    }

    @Test func changedHostKeyIsAskedAndCancelStops() async throws {
        let box = try RemoteSandbox()
        try box.prepare()
        var known = KnownHosts(file: box.knownHosts)
        var fake = server.hostKeyBlob
        fake[fake.count - 1] ^= 0xFF
        try known.remember(host: "[127.0.0.1]:\(server.port)", key: fake)
        let registry = ProviderRegistry()
        registry.register(connector: server.connector(knownHosts: box.knownHosts))
        let prompts = TestPrompts(hostKey: .cancel)
        await #expect(throws: RemoteCancelled.self) {
            _ = try await registry.connect(server.target(path: box.path), prompts: prompts)
        }
        #expect(prompts.state.withLock { $0.hostKeyQuestions.first?.reason } == .changed)
        #expect(registry.openConnections.isEmpty)
        // Trust once: connects, keeps the old line.
        let once = TestPrompts(hostKey: .trustOnce)
        let start = try await registry.connect(server.target(path: box.path), prompts: once)
        #expect(KnownHosts(file: box.knownHosts).check(host: "[127.0.0.1]:\(server.port)", key: server.hostKeyBlob) == .changed)
        await registry.disconnect(start.location)
    }

    // MARK: Logins

    @Test func encryptedKeyAsksForThePassphraseUntilRight() async throws {
        let box = try RemoteSandbox()
        let prompts = TestPrompts(secrets: ["wrong", server.passphrase])
        let (registry, _, start) = try await connect(box, auth: .keyFile(server.secretKey), prompts: prompts)
        let requests = prompts.state.withLock { $0.secretRequests }
        #expect(requests.map(\.retry) == [false, true])
        #expect(requests.first?.kind == .passphrase(keyFile: server.secretKey))
        #expect(requests.first?.keychainKey == "ssh-key:\(server.secretKey)")
        #expect(prompts.state.withLock { $0.worked.count } == 1)
        await registry.disconnect(start.location)
    }

    @Test func cancelledPassphraseStops() async throws {
        let box = try RemoteSandbox()
        await #expect(throws: RemoteCancelled.self) {
            _ = try await connect(box, auth: .keyFile(server.secretKey), prompts: TestPrompts(secrets: [nil]))
        }
    }

    @Test func agentLogsIn() async throws {
        let box = try RemoteSandbox()
        let prompts = TestPrompts()
        let (registry, provider, start) = try await connect(box, auth: .automatic, agent: true, prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.isEmpty })
        #expect(provider.connectionTitle == "\(NSUserName())@127.0.0.1:\(server.port)")
        await registry.disconnect(start.location)
    }

    @Test func sshConfigAliasIsFollowed() async throws {
        let box = try RemoteSandbox()
        try box.prepare()
        try box.trustServer(server)
        try """
        Host basil-test
            HostName 127.0.0.1
            Port \(server.port)
            IdentityFile \(server.plainKey)
            ProxyCommand none
        """.write(to: server.home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: server.home.appendingPathComponent(".ssh/config")) }
        let registry = ProviderRegistry()
        let connector = server.connector(knownHosts: box.knownHosts)
        registry.register(connector: connector)
        #expect(connector.knownHosts() == ["basil-test"])
        let prompts = TestPrompts()
        let start = try await registry.connect(RemoteTarget(service: .sftp, host: "basil-test", path: box.path), prompts: prompts)
        #expect(start.location.instance == "\(NSUserName())@127.0.0.1:\(server.port)")
        #expect(prompts.state.withLock { $0.notes.first?.contains("ProxyCommand") } == true)
        await registry.disconnect(start.location)
    }

    @Test func connectingTwiceReusesTheConnection() async throws {
        let box = try RemoteSandbox()
        let (registry, provider, start) = try await connect(box)
        let again = try await registry.connect(server.target(path: box.path + "/.."), prompts: TestPrompts())
        #expect(again.location == start.location)
        #expect(try registry.provider(for: start.location) as? SFTPProvider === provider)
        #expect(registry.openConnections.count == 1)
        await registry.disconnect(start.location)
        #expect(registry.openConnections.isEmpty)
    }

    // MARK: Files

    @Test func listsAndChangesFiles() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let local = URL(fileURLWithPath: box.path)
        try Data("hello".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data().write(to: local.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: local.appendingPathComponent("link").path, withDestinationPath: "sub")
        try FileManager.default.createSymbolicLink(atPath: local.appendingPathComponent("dead").path, withDestinationPath: "nowhere")

        var items: [FileItem] = []
        for try await batch in sftp.list(root) { items += batch }
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a.txt", ".hidden", "sub", "link", "dead"])
        #expect(byName["a.txt"]?.size == 5 && byName["a.txt"]?.kind == .file)
        #expect(byName[".hidden"]?.isHidden == true)
        #expect(byName["sub"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symlink(target: .directory))
        #expect(byName["dead"]?.kind == .symlink(target: .broken))
        #expect(try await sftp.readSymlink(root.appending("link")) == "sub")

        // Write, flush, rename into place, read back.
        let partial = root.appending(".basil-partial-x")
        let file = try await sftp.createFile(partial)
        try await file.write(Data("0123456789".utf8), at: 0)
        try await file.write(Data("AB".utf8), at: 4)
        try await file.truncate(to: 8)
        try await file.synchronize()
        _ = try await file.apply(FileMetadata(permissions: 0o640, modified: timespec(tv_sec: 1_000_000_000, tv_nsec: 0)))
        await file.close()
        await #expect(throws: VFSError.alreadyExists(partial)) { _ = try await sftp.createFile(partial) }
        await #expect(throws: VFSError.alreadyExists(root.appending("a.txt"))) {
            try await sftp.rename(partial, to: root.appending("a.txt"), replacing: false)
        }
        try await sftp.rename(partial, to: root.appending("a.txt"), replacing: true)
        #expect(try Data(contentsOf: local.appendingPathComponent("a.txt")) == Data("0123AB67".utf8))
        let item = try await sftp.item(at: root.appending("a.txt"))
        #expect(item.permissions == 0o640)
        #expect(item.modified == Date(timeIntervalSince1970: 1_000_000_000))
        let reader = try await sftp.openForReading(root.appending("a.txt"), bypassCache: false)
        #expect(try await reader.read(at: 2, count: 100) == Data("23AB67".utf8))
        await reader.close()

        // Folders, links, removal.
        try await sftp.makeDirectory(root.appending("new"))
        await #expect(throws: VFSError.alreadyExists(root.appending("new"))) { try await sftp.makeDirectory(root.appending("new")) }
        try await sftp.createSymlink(root.appending("new/ln"), target: "../a.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.appendingPathComponent("new/ln").path) == "../a.txt")
        await #expect(throws: VFSError.directoryNotEmpty(root.appending("new"))) { try await sftp.remove(root.appending("new")) }
        try await sftp.remove(root.appending("new/ln"))
        try await sftp.remove(root.appending("new"))
        await #expect(throws: VFSError.notFound(root.appending("new"))) { _ = try await sftp.item(at: root.appending("new")) }
        await #expect(throws: VFSError.notADirectory(root.appending("a.txt"))) {
            for try await _ in sftp.list(root.appending("a.txt")) {}
        }
        #expect(try await sftp.volumeIdentifier(of: root)?.hasPrefix("sftp:") == true)
    }

    @Test func reconnectsAfterTheConnectionDropped() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        try await sftp.connection.run { sftp.connection.tearDown() }
        _ = try await sftp.item(at: root)
        #expect(sftp.connection.generation == 2)
    }

    // MARK: Copy engine

    func engine(_ registry: ProviderRegistry, secure: Bool = true,
                afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> SecureCopyEngine {
        SecureCopyEngine(registry: registry, options: SecureCopyOptions(retryDelay: .milliseconds(1), secure: secure),
                         monitor: Monitor(), hooks: EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.rename, .clone, .stream]))
    }

    func localFile(_ box: RemoteSandbox, _ name: String, _ data: Data) throws -> VFSPath {
        let url = box.folder.appendingPathComponent(name)
        try data.write(to: url)
        return .local(url.path)
    }

    @Test func copiesATreeUpAndDown() async throws {
        let box = try RemoteSandbox()
        let (registry, _, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let tree = box.folder.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let big = randomData(3 * mb + 77)
        try big.write(to: tree.appendingPathComponent("inner/big.bin"))
        try Data("x".utf8).write(to: tree.appendingPathComponent("small.txt"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("ln").path, withDestinationPath: "small.txt")

        let up = try await engine(registry).transfer(.local(tree.path), to: root.appending("tree"), mode: .copy)
        #expect(up.failed.isEmpty)
        let served = URL(fileURLWithPath: box.path).appendingPathComponent("tree")
        #expect(try Data(contentsOf: served.appendingPathComponent("inner/big.bin")) == big)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: served.appendingPathComponent("ln").path) == "small.txt")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: served.path).contains { $0.hasPrefix(".basil-partial-") })

        let back = box.folder.appendingPathComponent("back")
        _ = try await engine(registry).transfer(root.appending("tree"), to: .local(back.path), mode: .move)
        #expect(try Data(contentsOf: back.appendingPathComponent("inner/big.bin")) == big)
        #expect(!FileManager.default.fileExists(atPath: served.path))
    }

    @Test func moveOnTheServerRenames() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        try Data("m".utf8).write(to: URL(fileURLWithPath: box.path).appendingPathComponent("m.txt"))
        try await sftp.makeDirectory(root.appending("to"))
        let result = try await engine(registry).transferFile(root.appending("m.txt"), to: root.appending("to/m.txt"),
                                                             mode: .move, sftp, sftp)
        #expect(result.strategy == .rename)
        #expect(FileManager.default.fileExists(atPath: box.path + "/to/m.txt"))
    }

    /// F4 on the server: the edited copy goes up over the unchanged file; after someone else
    /// changed the file, the upload asks and Cancel keeps their version.
    @MainActor
    @Test func uploadsAnEditedCopyAndAsksAfterAChangeOnTheServer() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let served = URL(fileURLWithPath: box.path).appendingPathComponent("notes.txt")
        try Data("server text".utf8).write(to: served)
        let remote = root.appending("notes.txt")
        let downloaded = try await sftp.fingerprint(of: remote)
        let copy = try localFile(box, "notes.txt", Data("edited text, longer".utf8))
        let queue = FileOperationQueue()
        var asked = 0
        queue.promptHandler = { _, prompt in
            guard case .changedOnServer = prompt else { return .itemFailed(.cancel) }
            asked += 1
            return .changedOnServer(replace: false)
        }
        func upload(_ then: FileFingerprint?) async -> (QueueItem, UploadEditedCopyOperation) {
            let op = UploadEditedCopyOperation(copy: copy, destination: remote, downloaded: then, server: "test",
                                               registry: registry, options: SecureCopyOptions())
            let item = queue.add(op)
            while !item.state.isDone { try? await Task.sleep(for: .milliseconds(20)) }
            return (item, op)
        }
        let (first, op) = await upload(downloaded)
        #expect(first.state == .finished)
        #expect(asked == 0)
        #expect(try Data(contentsOf: served) == Data("edited text, longer".utf8))
        let uploaded = try #require(op.result.fingerprint)

        try Data("someone else".utf8).write(to: served)
        let (second, _) = await upload(uploaded)
        #expect(asked == 1)
        #expect(second.state == .cancelled)
        #expect(try Data(contentsOf: served) == Data("someone else".utf8))
    }

    // Local source changing while it is copied to the server: the delta pass writes into the
    // remote partial file at offsets and truncates it.

    @Test func localSourceAppendedDuringUpload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let src = try localFile(box, "a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 3 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: root.appending("a.bin"), mode: .copy, LocalProvider(), sftp)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin")) == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let src = try localFile(box, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(src, to: root.appending("a.bin"), mode: .copy, LocalProvider(), sftp)
        #expect(result.retries == 1)
        let copied = try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin"))
        let original = try Data(contentsOf: URL(fileURLWithPath: src.path))
        #expect(copied.count == mb + 1000 && copied == original)
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let src = try localFile(box, "a.bin", randomData(4 * mb))
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: src.path))
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(src, to: root.appending("a.bin"), mode: .copy, LocalProvider(), sftp)
        #expect(result.retries == 1)
        #expect(result.bytesRewritten == Int64(mb))
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path + "/a.bin")) == Data(contentsOf: URL(fileURLWithPath: src.path)))
    }

    // A remote source changing during a download. SFTP reports size and whole-second mtimes, so
    // a change is seen when the size changes or a second has passed.

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(3 * mb + 100).write(to: served)
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: served)
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb)); try! h.close()
                }
            }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(root.appending("r.bin"), to: target, mode: .copy, sftp, LocalProvider())
        #expect(result.retries >= 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == Data(contentsOf: served))
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(4 * mb).write(to: served)
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(served.path, off_t(2 * mb + 5)) } }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(root.appending("r.bin"), to: target, mode: .copy, sftp, LocalProvider())
        #expect(result.retries >= 1)
        let copied = try Data(contentsOf: URL(fileURLWithPath: target.path))
        let original = try Data(contentsOf: served)
        #expect(copied.count == 2 * mb + 5 && copied == original)
    }

    @Test func remoteSourceRewrittenAfterASecondDuringDownload() async throws {
        let box = try RemoteSandbox()
        let (registry, sftp, root) = try await connect(box)
        defer { Task { await registry.disconnect(root.location) } }
        let served = URL(fileURLWithPath: box.path + "/r.bin")
        try randomData(3 * mb).write(to: served)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: served.path)
        let once = Once()
        let copy = engine(registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: served)
                    try! h.seek(toOffset: 100); try! h.write(contentsOf: randomData(50)); try! h.close()
                }
            }
        }
        let target = VFSPath.local(box.folder.appendingPathComponent("r.bin").path)
        let result = try await copy.transferFile(root.appending("r.bin"), to: target, mode: .copy, sftp, LocalProvider())
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path)) == Data(contentsOf: served))
    }
}
