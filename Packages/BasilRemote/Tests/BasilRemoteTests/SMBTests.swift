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

private func engine(_ registry: ProviderRegistry, afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> SecureCopyEngine {
    SecureCopyEngine(registry: registry, options: SecureCopyOptions(retryDelay: .milliseconds(1), secure: true),
                     monitor: Monitor(), hooks: EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.rename, .clone, .stream]))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-smb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// SMB through macOS's own client against Samba in Docker: logins, the share list, mounting and
/// unmounting, file changes through the mount, and the copy engine with sources that change
/// during copies both ways. Skipped when Docker is not running.
@Suite(.serialized, .enabled(if: SMBTestServer.shared != nil, "Docker (OrbStack) is not running"))
struct SMBTests {
    let server = SMBTestServer.shared!

    struct Connection {
        let registry: ProviderRegistry
        let smb: SMBProvider
        let start: VFSPath
        let prompts: FTPPrompts
        func close() async { await registry.disconnect(start.location) }
        /// A path on the server.
        func path(_ path: String) -> VFSPath { VFSPath(location: smb.location, path: path) }
        /// The local file of a server path (its share is mounted).
        func local(_ path: VFSPath) throws -> URL { URL(fileURLWithPath: try #require(smb.localPath(of: path))) }
    }

    func connect(path: String? = nil, user: String? = nil, prompts: FTPPrompts? = nil) async throws -> Connection {
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        registry.register(connector: SMBConnector())
        let prompts = prompts ?? FTPPrompts(secrets: [server.password])
        let start = try await registry.connect(server.target(path: path, user: user), prompts: prompts)
        let smb = try #require(try registry.provider(for: start.location) as? SMBProvider)
        return Connection(registry: registry, smb: smb, start: start, prompts: prompts)
    }

    /// Connects and makes a fresh folder in the share files.
    func sandbox() async throws -> Connection {
        let c = try await connect()
        let folder = c.path("/files/t-\(UUID().uuidString.prefix(8))")
        try await c.smb.makeDirectory(folder)
        return Connection(registry: c.registry, smb: c.smb, start: folder, prompts: c.prompts)
    }

    func names(_ c: Connection, _ path: VFSPath) async throws -> Set<String> {
        var names: Set<String> = []
        for try await batch in c.smb.list(path) { names.formUnion(batch.map(\.name)) }
        return names
    }

    // MARK: Connecting

    @Test func listsTheSharesAtTheTop() async throws {
        let c = try await connect()
        #expect(c.start.path == "/")
        #expect(c.smb.connectionTitle == "alice@\(server.host)")
        #expect(c.prompts.state.withLock { $0.secretRequests.first?.keychainKey } == "smb:alice@\(server.host)")
        #expect(c.prompts.state.withLock { $0.worked } == 1)
        // Disk shares only: no IPC$.
        #expect(try await names(c, c.start) == ["files", "media", "open"])
        // Nothing is mounted until a share is used.
        #expect(c.smb.ownMounts.isEmpty)
        await c.close()
    }

    @Test func startFolderMountsItsShareAndDisconnectUnmountsIt() async throws {
        let c = try await connect(path: "/files")
        let mount = try #require(c.smb.ownMounts.first)
        #expect(mount.hasPrefix("/Volumes/"))
        #expect(SMBClient.isMounted(mount))
        // A second share of the same server is mounted when it is listed.
        _ = try await names(c, c.path("/media"))
        #expect(c.smb.ownMounts.count == 2)
        let mounts = c.smb.ownMounts
        await c.close()
        for path in mounts { #expect(!SMBClient.isMounted(path)) }
    }

    @Test func shareMountedBeforeStaysMounted() async throws {
        let endpoint = SMBEndpoint(host: server.host, port: nil, user: server.user)
        let mount = try await SMBClient.mount("media", endpoint: endpoint, password: server.password)
        defer { Darwin.unmount(mount, 0) }
        let c = try await connect(path: "/media")
        #expect(c.smb.ownMounts.isEmpty)
        #expect(c.smb.localPath(of: c.start) == mount)
        await c.close()
        #expect(SMBClient.isMounted(mount))
    }

    /// macOS keeps a logged-in session for a few seconds after the last share was unmounted and
    /// accepts any password while it lasts: wait until a wrong password fails again.
    func waitUntilLoggedOut() async throws {
        let endpoint = SMBEndpoint(host: server.host, port: nil, user: server.user)
        for _ in 0..<60 {
            do {
                _ = try await SMBClient.shares(endpoint, password: "certainly wrong")
            } catch let error as SMBError where error.code == EAUTH {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("macOS stayed logged in to the server")
    }

    @Test func loggedInSessionAsksNoPassword() async throws {
        let endpoint = SMBEndpoint(host: server.host, port: nil, user: server.user)
        let mount = try await SMBClient.mount("media", endpoint: endpoint, password: server.password)
        defer { Darwin.unmount(mount, 0) }
        let c = try await connect(path: "/files", prompts: FTPPrompts(secrets: []))
        #expect(c.prompts.state.withLock { $0.secretRequests.isEmpty && $0.worked == 0 })
        #expect(c.smb.ownMounts.count == 1)
        await c.close()
    }

    /// Right after Basil's last share of the server was unmounted macOS still takes any
    /// password: a password to remember is checked only once that session has ended, so a
    /// wrong one is refused (and never saved).
    @Test func aPasswordToRememberIsCheckedAfterTheSessionEnded() async throws {
        let first = try await connect(path: "/files")
        await first.close()
        let prompts = FTPPrompts(secrets: ["wrong", server.password])
        prompts.state.withLock { $0.remember = true }
        let c = try await connect(prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.map(\.retry) } == [false, true])
        #expect(prompts.state.withLock { $0.worked } == 1)
        await c.close()
    }

    @Test func wrongPasswordIsAskedAgain() async throws {
        try await waitUntilLoggedOut()
        let prompts = FTPPrompts(secrets: ["wrong", server.password])
        let c = try await connect(prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.map(\.retry) } == [false, true])
        await c.close()
    }

    @Test func threeWrongPasswordsStop() async throws {
        try await waitUntilLoggedOut()
        await #expect(throws: VFSError.self) {
            _ = try await connect(prompts: FTPPrompts(secrets: ["a", "b", "c"]))
        }
    }

    @Test func cancelledPasswordStops() async throws {
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(prompts: FTPPrompts(secrets: [nil])) }
    }

    @Test func guestListsAndUsesTheOpenShare() async throws {
        let c = try await connect(path: "/open", user: "", prompts: FTPPrompts(secrets: []))
        #expect(c.prompts.state.withLock { $0.secretRequests.isEmpty })
        #expect(c.smb.connectionTitle == server.host)
        let file = c.path("/open/guest-\(UUID().uuidString.prefix(8)).txt")
        try Data("hi".utf8).write(to: try c.local(file))
        #expect(try await c.smb.item(at: file).size == 2)
        try await c.smb.remove(file)
        await c.close()
    }

    @Test func missingShareSaysSo() async throws {
        do {
            _ = try await connect(path: "/nothing-here")
            Issue.record("connected to a missing share")
        } catch {
            #expect(error.localizedDescription.contains("has no share named nothing-here"))
        }
    }

    @Test func missingFolderSaysSo() async throws {
        await #expect(throws: VFSError.self) { _ = try await connect(path: "/files/not-there") }
    }

    // MARK: Files

    @Test func changesFilesAndFolders() async throws {
        let c = try await sandbox()
        let sub = c.start.appending("sub")
        try await c.smb.makeDirectory(sub)
        let file = try await c.smb.createFile(c.start.appending("a.txt"))
        #expect(file.path == c.start.appending("a.txt"))
        try await file.write(Data("hello".utf8), at: 0)
        try await file.synchronize()
        await file.close()
        #expect(try await names(c, c.start) == ["sub", "a.txt"])
        let item = try await c.smb.item(at: c.start.appending("a.txt"))
        #expect(item.size == 5 && item.path == c.start.appending("a.txt"))

        // Without replacing: smbfs has no exclusive rename, so the target is checked first.
        try await c.smb.rename(c.start.appending("a.txt"), to: c.start.appending("b.txt"), replacing: false)
        let other = try await c.smb.createFile(c.start.appending("c.txt"))
        await other.close()
        await #expect(throws: VFSError.alreadyExists(c.start.appending("c.txt"))) {
            try await c.smb.rename(c.start.appending("b.txt"), to: c.start.appending("c.txt"), replacing: false)
        }
        try await c.smb.rename(c.start.appending("b.txt"), to: c.start.appending("c.txt"), replacing: true)
        // Only the case changes.
        try await c.smb.rename(c.start.appending("c.txt"), to: c.start.appending("C.txt"), replacing: false)
        #expect(try await names(c, c.start) == ["sub", "C.txt"])

        // Errors name the share's paths.
        await #expect(throws: VFSError.notFound(c.start.appending("missing"))) {
            _ = try await c.smb.item(at: c.start.appending("missing"))
        }
        // Shares are not files.
        await #expect(throws: VFSError.self) { try await c.smb.makeDirectory(c.path("/newshare")) }
        await #expect(throws: VFSError.self) { try await c.smb.remove(c.path("/files")) }
        await #expect(throws: VFSError.self) {
            try await c.smb.rename(c.start.appending("C.txt"), to: c.path("/media/C.txt"), replacing: false)
        }

        try await c.smb.remove(c.start.appending("C.txt"))
        try await c.smb.remove(sub)
        try await c.smb.remove(c.start)
        await c.close()
    }

    @Test func watchReportsChangesInTheShare() async throws {
        let c = try await sandbox()
        let changes = try #require(c.smb.watch(c.start))
        let seen = Task { () -> VFSChange? in
            for await change in changes { return change }
            return nil
        }
        try await Task.sleep(for: .milliseconds(500))
        try Data("x".utf8).write(to: try c.local(c.start.appending("w.txt")))
        let change = try await withThrowingTaskGroup(of: VFSChange?.self) { group in
            group.addTask { await seen.value }
            group.addTask { try await Task.sleep(for: .seconds(10)); seen.cancel(); return nil }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        switch change {
        case .item(let path): #expect(path.location == c.smb.location && path.path.hasPrefix(c.start.path))
        case .reloadAll: break
        case nil: Issue.record("no change was reported")
        }
        try await c.smb.remove(c.start.appending("w.txt"))
        try await c.smb.remove(c.start)
        await c.close()
    }

    // MARK: Copy engine

    @Test func moveInsideAShareRenames() async throws {
        let c = try await sandbox()
        let data = randomData(100_000)
        try data.write(to: try c.local(c.start.appending("m.bin")))
        try await c.smb.makeDirectory(c.start.appending("into"))
        let result = try await engine(c.registry).transferFile(c.start.appending("m.bin"), to: c.start.appending("into/m.bin"),
                                                               mode: .move, c.smb, c.smb)
        #expect(result.strategy == .rename)
        #expect(try Data(contentsOf: try c.local(c.start.appending("into/m.bin"))) == data)
        #expect(try await names(c, c.start) == ["into"])
        await c.close()
    }

    @Test func copyInsideAShareStreamsWhenTheServerCannotClone() async throws {
        let c = try await sandbox()
        let data = randomData(3 * mb + 7)
        try data.write(to: try c.local(c.start.appending("s.bin")))
        _ = try await engine(c.registry).transferFile(c.start.appending("s.bin"), to: c.start.appending("t.bin"),
                                                      mode: .copy, c.smb, c.smb)
        #expect(try Data(contentsOf: try c.local(c.start.appending("t.bin"))) == data)
        await c.close()
    }

    @Test func localSourceAppendedDuringUpload() async throws {
        let c = try await sandbox()
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(4 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    let h = try! FileHandle(forWritingTo: src)
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let target = c.start.appending("a.bin")
        let result = try await copy.transferFile(.local(src.path), to: target, mode: .copy, LocalProvider(), c.smb)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: try c.local(target)) == Data(contentsOf: src))
        await c.close()
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let c = try await sandbox()
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(4 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let target = c.start.appending("a.bin")
        let result = try await copy.transferFile(.local(src.path), to: target, mode: .copy, LocalProvider(), c.smb)
        #expect(result.retries == 1)
        let copied = try Data(contentsOf: try c.local(target))
        let original = try Data(contentsOf: src)
        #expect(copied.count == mb + 1000 && copied == original)
        await c.close()
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let c = try await sandbox()
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(4 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: src)
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let target = c.start.appending("a.bin")
        let result = try await copy.transferFile(.local(src.path), to: target, mode: .copy, LocalProvider(), c.smb)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: try c.local(target)) == Data(contentsOf: src))
        await c.close()
    }

    // A source on the share changed by another computer (smbclient in the container) during a
    // download.

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let c = try await sandbox()
        let source = c.start.appending("r.bin")
        try randomData(3 * mb + 100).write(to: try c.local(source))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    try! server.otherClient(source.path, make: "{ cat $F; head -c 1048576 /dev/urandom; } > /tmp/new")
                }
            }
        }
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(source, to: .local(target.path), mode: .copy, c.smb, LocalProvider())
        #expect(result.retries >= 1)
        #expect(try Data(contentsOf: target).count == 4 * mb + 100)
        #expect(try Data(contentsOf: target) == Data(contentsOf: try c.local(source)))
        await c.close()
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let c = try await sandbox()
        let source = c.start.appending("r.bin")
        try randomData(4 * mb).write(to: try c.local(source))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 {
                once { try! server.otherClient(source.path, make: "head -c \(2 * mb + 5) $F > /tmp/new") }
            }
        }
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(source, to: .local(target.path), mode: .copy, c.smb, LocalProvider())
        #expect(result.retries >= 1)
        let copied = try Data(contentsOf: target)
        let original = try Data(contentsOf: try c.local(source))
        #expect(copied.count == 2 * mb + 5 && copied == original)
        await c.close()
    }

    @Test func remoteSourceRewrittenInTheMiddleDuringDownload() async throws {
        let c = try await sandbox()
        let source = c.start.appending("r.bin")
        try randomData(3 * mb).write(to: try c.local(source))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 1 {
                once {
                    try! server.otherClient(source.path, make: "cp $F /tmp/new && head -c 50 /dev/urandom | dd of=/tmp/new bs=1 seek=100 conv=notrunc 2>/dev/null")
                }
            }
        }
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(source, to: .local(target.path), mode: .copy, c.smb, LocalProvider())
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: target) == Data(contentsOf: try c.local(source)))
        await c.close()
    }
}
