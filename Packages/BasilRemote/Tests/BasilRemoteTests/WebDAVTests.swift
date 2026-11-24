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

struct WebDAVConnection {
    let registry: ProviderRegistry
    let dav: WebDAVProvider
    let start: VFSPath
    let prompts: FTPPrompts
    func close() async { await registry.disconnect(start.location) }
}

private func connect(_ target: RemoteTarget, secure: Bool = false, prompts: FTPPrompts, trustFile: URL? = nil) async throws -> WebDAVConnection {
    let registry = ProviderRegistry()
    registry.register(LocalProvider())
    let trust = trustFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("basil-trust-\(UUID().uuidString)")
    registry.register(connector: WebDAVConnector(secure: secure, trustFile: trust))
    let start = try await registry.connect(target, prompts: prompts)
    let dav = try #require(try registry.provider(for: start.location) as? WebDAVProvider)
    return WebDAVConnection(registry: registry, dav: dav, start: start, prompts: prompts)
}

/// A local scratch folder.
private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-webdav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The WebDAV client against Apache's mod_dav: logins, certificates, file changes, and the copy
/// engine with sources that change during uploads and downloads.
@Suite(.serialized) struct WebDAVTests {
    let server: WebDAVTestServer
    init() throws { server = try #require(WebDAVTestServer.shared, "httpd could not be started") }

    func connect(share: String = "dav", secure: Bool = false, user: String? = nil, prompts: FTPPrompts? = nil,
                 trustFile: URL? = nil) async throws -> (WebDAVConnection, URL) {
        let (name, url) = try server.sandbox()
        let prompts = prompts ?? FTPPrompts(secrets: [server.password])
        let c = try await BasilRemoteTests.connect(server.target(secure: secure, share: share, folder: name, user: user),
                                                   secure: secure, prompts: prompts, trustFile: trustFile)
        return (c, url)
    }

    // MARK: Connecting

    @Test(arguments: ["dav", "digest"])
    func logsInFindsTheTopAndLists(_ share: String) async throws {
        let (c, folder) = try await connect(share: share)
        defer { Task { await c.close() } }
        // The top is the share; the start folder is the sandbox inside it.
        #expect(c.dav.root == "/\(share)")
        #expect(c.start.path == "/" + folder.lastPathComponent)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a b é.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var items: [FileItem] = []
        for try await batch in c.dav.list(c.start) { items += batch }
        let names = Set(items.map(\.name))
        #expect(names == ["a b é.txt", "sub"])
        let file = try #require(items.first { $0.name == "a b é.txt" })
        #expect(file.size == 5 && file.kind == .file)
        #expect(items.first { $0.name == "sub" }?.kind == .directory)
        #expect(c.prompts.state.withLock { $0.secretRequests.count } == 1)
        #expect(c.prompts.state.withLock { $0.worked } == 1)
        // Up to the top.
        var top: [FileItem] = []
        for try await batch in c.dav.list(VFSPath(location: c.start.location, path: "/")) { top += batch }
        #expect(top.contains { $0.name == folder.lastPathComponent })
    }

    @Test func noLoginAsksNothing() async throws {
        let (c, _) = try await connect(share: "open", user: "", prompts: FTPPrompts(secrets: []))
        defer { Task { await c.close() } }
        #expect(c.prompts.state.withLock { $0.secretRequests.isEmpty })
        #expect(c.dav.connectionTitle == "127.0.0.1:\(server.port)")
    }

    @Test func wrongPasswordIsAskedAgain() async throws {
        let prompts = FTPPrompts(secrets: ["wrong", server.password])
        let (c, _) = try await connect(prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.map(\.retry) } == [false, true])
        #expect(prompts.state.withLock { $0.secretRequests.first?.keychainKey } == "webdav:alice@127.0.0.1:\(server.port)")
        await c.close()
    }

    @Test func cancelledPasswordStops() async throws {
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(prompts: FTPPrompts(secrets: [nil])) }
    }

    @Test func missingUserSaysSo() async throws {
        await #expect(throws: VFSError.self) { _ = try await connect(user: "", prompts: FTPPrompts(secrets: [])) }
    }

    @Test func missingFolderSaysSo() async throws {
        let target = RemoteTarget(service: .webdav, host: "127.0.0.1", port: server.port, user: server.user,
                                  path: "/dav/not-there", authentication: .password)
        do {
            _ = try await BasilRemoteTests.connect(target, prompts: FTPPrompts(secrets: [server.password]))
            Issue.record("connected to a missing folder")
        } catch let error as VFSError {
            #expect(error.localizedDescription.contains("has no folder /dav/not-there"))
        }
    }

    @Test func untrustedCertificateIsAskedAndRemembered() async throws {
        let trust = try scratch().appendingPathComponent("trusted")
        let first = FTPPrompts(certificate: .trustAndRemember, secrets: [server.password])
        let (c, _) = try await connect(secure: true, prompts: first, trustFile: trust)
        let question = try #require(first.state.withLock { $0.certificateQuestions.first })
        guard case .untrusted = question.reason else { Issue.record("expected an untrusted certificate"); return }
        #expect(question.subject == "localhost")
        #expect(question.host == "127.0.0.1:\(server.tlsPort)")
        // Requests after the first one use the accepted certificate.
        try await c.dav.makeDirectory(c.start.appending("made"))
        await c.close()

        let again = FTPPrompts(certificate: .cancel, secrets: [server.password])
        let (d, _) = try await connect(secure: true, prompts: again, trustFile: trust)
        #expect(again.state.withLock { $0.certificateQuestions.isEmpty })
        await d.close()

        // Cancelled: no connection, no password asked.
        let refused = FTPPrompts(certificate: .cancel, secrets: [server.password])
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(secure: true, prompts: refused) }
        #expect(refused.state.withLock { $0.secretRequests.isEmpty })
    }

    // MARK: Changes

    @Test func changesFilesAndFolders() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let dav = c.dav
        let here = c.start
        try await dav.makeDirectory(here.appending("new folder"))
        await #expect(throws: VFSError.alreadyExists(here.appending("new folder"))) {
            try await dav.makeDirectory(here.appending("new folder"))
        }
        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("two.txt"))
        // Rename refuses an existing name unless replacing.
        await #expect(throws: VFSError.alreadyExists(here.appending("two.txt"))) {
            try await dav.rename(here.appending("one.txt"), to: here.appending("two.txt"), replacing: false)
        }
        try await dav.rename(here.appending("one.txt"), to: here.appending("two.txt"), replacing: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("two.txt"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.txt").path))
        // Server-side copy.
        try await dav.clone(here.appending("two.txt"), to: here.appending("new folder/copy.txt"))
        #expect(try String(contentsOf: folder.appendingPathComponent("new folder/copy.txt"), encoding: .utf8) == "one")
        await #expect(throws: VFSError.alreadyExists(here.appending("two.txt"))) {
            try await dav.clone(here.appending("new folder/copy.txt"), to: here.appending("two.txt"))
        }
        // A full folder is not removed.
        await #expect(throws: VFSError.directoryNotEmpty(here.appending("new folder"))) {
            try await dav.remove(here.appending("new folder"))
        }
        try await dav.remove(here.appending("new folder/copy.txt"))
        try await dav.remove(here.appending("new folder"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("new folder").path))
        await #expect(throws: VFSError.notFound(here.appending("gone"))) { try await dav.remove(here.appending("gone")) }
        // No trash on a plain server.
        #expect(!dav.capabilities.contains(.trash))
    }

    @Test func readsAtOffsets() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let data = randomData(5 * mb + 123)
        try data.write(to: folder.appendingPathComponent("r.bin"))
        let file = try await c.dav.openForReading(c.start.appending("r.bin"), bypassCache: false)
        #expect(try await file.read(at: 0, count: 1000) == data.prefix(1000))
        #expect(try await file.read(at: 1000, count: mb) == data.subdata(in: 1000..<(1000 + mb)))
        #expect(try await file.read(at: Int64(4 * mb), count: 2 * mb) == data.subdata(in: (4 * mb)..<data.count))
        #expect(try await file.read(at: Int64(data.count), count: 10).isEmpty)
        #expect(try await file.read(at: 10, count: 5) == data.subdata(in: 10..<15))
        await file.close()
    }

    // MARK: Copies

    @Test(arguments: ["dav", "digest"])
    func copiesATreeUpAndDownAndOnTheServer(_ share: String) async throws {
        let (c, folder) = try await connect(share: share)
        defer { Task { await c.close() } }
        let local = try scratch()
        let tree = local.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner"), withIntermediateDirectories: true)
        // Larger than a file kept in memory: streamed.
        let big = randomData(12 * mb + 77)
        try big.write(to: tree.appendingPathComponent("inner/big.bin"))
        try Data("x".utf8).write(to: tree.appendingPathComponent("small.txt"))

        let up = try await engine(c.registry).transfer(.local(tree.path), to: c.start.appending("tree"), mode: .copy)
        #expect(up.failed.isEmpty)
        let served = folder.appendingPathComponent("tree")
        #expect(try Data(contentsOf: served.appendingPathComponent("inner/big.bin")) == big)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: served.path).contains { $0.hasPrefix(".basil-partial-") })

        _ = try await engine(c.registry).transfer(c.start.appending("tree"), to: c.start.appending("copy"), mode: .copy)
        #expect(try Data(contentsOf: folder.appendingPathComponent("copy/inner/big.bin")) == big)

        let back = local.appendingPathComponent("back")
        _ = try await engine(c.registry).transfer(c.start.appending("tree"), to: .local(back.path), mode: .move)
        #expect(try Data(contentsOf: back.appendingPathComponent("inner/big.bin")) == big)
        #expect(!FileManager.default.fileExists(atPath: served.path))
    }

    @Test func moveOnTheServerRenames() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        try Data("m".utf8).write(to: folder.appendingPathComponent("m.txt"))
        try await c.dav.makeDirectory(c.start.appending("to"))
        let result = try await engine(c.registry).transferFile(c.start.appending("m.txt"), to: c.start.appending("to/m.txt"),
                                                               mode: .move, c.dav, c.dav)
        #expect(result.strategy == .rename)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("to/m.txt").path))
    }

    @Test func serverWantingLengthsGetsATemporaryCopy() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        c.dav.needsLength.withLock { $0 = true }
        let local = try scratch()
        let data = randomData(11 * mb + 5)
        try data.write(to: local.appendingPathComponent("s.bin"))
        _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent("s.bin").path),
                                                      to: c.start.appending("s.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(try Data(contentsOf: folder.appendingPathComponent("s.bin")) == data)
    }

    // A local source changing during an upload: WebDAV cannot write at offsets, so the partial
    // file is written again from the start. 12 MB: streamed.

    @Test func localSourceAppendedDuringUpload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(12 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: src)
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(.local(src.path), to: c.start.appending("a.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("a.bin")) == Data(contentsOf: src))
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(12 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(src.path, off_t(mb + 1000)) } }
        }
        let result = try await copy.transferFile(.local(src.path), to: c.start.appending("a.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(result.retries == 1)
        let copied = try Data(contentsOf: folder.appendingPathComponent("a.bin"))
        let original = try Data(contentsOf: src)
        #expect(copied.count == mb + 1000 && copied == original)
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(12 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: src)
                    try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(.local(src.path), to: c.start.appending("a.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("a.bin")) == Data(contentsOf: src))
    }

    // A remote source changing during a download: the ETag changes with the file.

    @Test func remoteSourceAppendedDuringDownload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let served = folder.appendingPathComponent("r.bin")
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
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(c.start.appending("r.bin"), to: .local(target.path), mode: .copy, c.dav, LocalProvider())
        #expect(result.retries >= 1)
        #expect(try Data(contentsOf: target) == Data(contentsOf: served))
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let served = folder.appendingPathComponent("r.bin")
        try randomData(4 * mb).write(to: served)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { once { Darwin.truncate(served.path, off_t(2 * mb + 5)) } }
        }
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(c.start.appending("r.bin"), to: .local(target.path), mode: .copy, c.dav, LocalProvider())
        #expect(result.retries >= 1)
        let copied = try Data(contentsOf: target)
        let original = try Data(contentsOf: served)
        #expect(copied.count == 2 * mb + 5 && copied == original)
    }

    @Test func remoteSourceRewrittenInTheMiddleDuringDownload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let served = folder.appendingPathComponent("r.bin")
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
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(c.start.appending("r.bin"), to: .local(target.path), mode: .copy, c.dav, LocalProvider())
        #expect(result.retries == 1)
        #expect(try Data(contentsOf: target) == Data(contentsOf: served))
    }
}

/// Nextcloud in Docker: found by status.php, its user's files as the top, chunked uploads with
/// dates and checksums, the trash bin. Skipped when Docker is not running.
@Suite(.serialized, .enabled(if: NextcloudTestServer.shared != nil))
struct NextcloudTests {
    var server: NextcloudTestServer { NextcloudTestServer.shared! }

    /// A connection and a fresh folder in the user's files.
    func connect(path: String? = nil) async throws -> (WebDAVConnection, VFSPath) {
        let c = try await BasilRemoteTests.connect(server.target(path: path), prompts: FTPPrompts(secrets: [server.password]))
        let folder = VFSPath(location: c.start.location, path: "/t-" + UUID().uuidString.prefix(8))
        try await c.dav.makeDirectory(folder)
        return (c, folder)
    }

    func contents(_ c: WebDAVConnection, _ path: VFSPath) async throws -> Data {
        let file = try await c.dav.openForReading(path, bypassCache: false)
        defer { Task { await file.close() } }
        var data = Data()
        while true {
            let part = try await file.read(at: Int64(data.count), count: 4 * mb)
            data.append(part)
            if part.count < 4 * mb { return data }
        }
    }

    @Test func findsNextcloudAndTheUsersFiles() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let nextcloud = try #require(c.dav.nextcloud)
        #expect(nextcloud.userID == server.user)
        #expect(nextcloud.trash)
        #expect(c.dav.root == "/remote.php/dav/files/\(server.user)")
        #expect(c.start.isRoot)
        #expect(c.dav.capabilities.contains(.trash) && c.dav.capabilities.contains(.setDates))
        // A path in the user's files is the start folder.
        let d = try await BasilRemoteTests.connect(server.target(path: "/remote.php/dav/files/\(server.user)\(folder.path)"),
                                                   prompts: FTPPrompts(secrets: [server.password]))
        #expect(d.start.path == folder.path)
        await d.close()
        let e = try await BasilRemoteTests.connect(server.target(path: "/remote.php/webdav\(folder.path)/"),
                                                   prompts: FTPPrompts(secrets: [server.password]))
        #expect(e.start.path == folder.path)
        await e.close()
    }

    @Test func uploadsInChunksWithDateAndChecksum() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        let src = local.appendingPathComponent("big.bin")
        let data = randomData(23 * mb + 11)
        try data.write(to: src)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: src.path)
        let small = local.appendingPathComponent("small.txt")
        try Data("small".utf8).write(to: small)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: small.path)

        for name in ["big.bin", "small.txt"] {
            _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent(name).path),
                                                          to: folder.appending(name), mode: .copy, LocalProvider(), c.dav)
            let metadata = try await c.dav.metadata(of: folder.appending(name))
            #expect(metadata.modified?.tv_sec == 1_600_000_000)
        }
        let stored = try await contents(c, folder.appending("big.bin"))
        #expect(stored == data)
        let response = try await c.dav.propfind(c.dav.url(folder.appending("big.bin")), depth: 0, extra: [("oc", "checksums")])
        let checksum = String(decoding: response.body, as: UTF8.self)
        #expect(checksum.contains("SHA1:"))
        // No leftover partial files or upload folders.
        var names: [String] = []
        for try await batch in c.dav.list(folder) { names += batch.map(\.name) }
        #expect(Set(names) == ["big.bin", "small.txt"])
    }

    @Test func localSourceAppendedDuringChunkedUpload() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(14 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 {
                once {
                    let h = try! FileHandle(forWritingTo: src)
                    try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
                }
            }
        }
        let result = try await copy.transferFile(.local(src.path), to: folder.appending("a.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(result.retries == 1)
        let stored = try await contents(c, folder.appending("a.bin"))
        let original = try Data(contentsOf: src)
        #expect(stored == original)
    }

    @Test func trashAndPermanentDelete() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        for name in ["keep.txt", "gone.txt"] {
            try Data(name.utf8).write(to: local.appendingPathComponent(name))
            _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent(name).path),
                                                          to: folder.appending(name), mode: .copy, LocalProvider(), c.dav)
        }
        try await c.dav.trash(folder.appending("keep.txt"))
        try await c.dav.remove(folder.appending("gone.txt"))
        let nc = try #require(c.dav.nextcloud)
        let response = try await c.dav.send("PROPFIND", c.dav.url(server: nc.trashBin, folder: true), headers: ["Depth": "1"],
                                            body: DAVXML.propfind(nextcloud: false, extra: [("nc", "trashbin-original-location")]))
        let places = try DAVXML.parse(response.body).compactMap { $0.value(DAVNamespace.nextcloud, "trashbin-original-location") }
        let relative = String(folder.path.dropFirst())
        #expect(places.contains(relative + "/keep.txt"))
        #expect(!places.contains(relative + "/gone.txt"))
        let left = try await c.dav.lookUp(folder.appending("keep.txt"))
        #expect(left == nil)
    }

    @Test func copiesAndMovesOnTheServer() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        try Data("c".utf8).write(to: local.appendingPathComponent("c.txt"))
        _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent("c.txt").path),
                                                      to: folder.appending("c.txt"), mode: .copy, LocalProvider(), c.dav)
        let copied = try await engine(c.registry).transferFile(folder.appending("c.txt"), to: folder.appending("d.txt"),
                                                               mode: .copy, c.dav, c.dav)
        #expect(copied.strategy == .clone)
        let moved = try await engine(c.registry).transferFile(folder.appending("d.txt"), to: folder.appending("e.txt"),
                                                              mode: .move, c.dav, c.dav)
        #expect(moved.strategy == .rename)
        let stored = try await contents(c, folder.appending("e.txt"))
        #expect(stored == Data("c".utf8))
    }
}

/// ownCloud 10: its chunked uploads, dates, trash bin and public links (the Nextcloud code with
/// ownCloud's paths and properties).
@Suite(.serialized, .enabled(if: OwnCloudTestServer.shared != nil))
struct OwnCloudTests {
    var server: OwnCloudTestServer { OwnCloudTestServer.shared! }

    func connect() async throws -> (WebDAVConnection, VFSPath) {
        let c = try await BasilRemoteTests.connect(server.target(), prompts: FTPPrompts(secrets: [server.password]))
        let folder = VFSPath(location: c.start.location, path: "/t-" + UUID().uuidString.prefix(8))
        try await c.dav.makeDirectory(folder)
        return (c, folder)
    }

    func contents(_ c: WebDAVConnection, _ path: VFSPath) async throws -> Data {
        let file = try await c.dav.openForReading(path, bypassCache: false)
        defer { Task { await file.close() } }
        var data = Data()
        while true {
            let part = try await file.read(at: Int64(data.count), count: 4 * mb)
            data.append(part)
            if part.count < 4 * mb { return data }
        }
    }

    @Test func findsOwnCloudAndItsExtras() async throws {
        let (c, _) = try await connect()
        defer { Task { await c.close() } }
        let server = try #require(c.dav.nextcloud)
        #expect(server.flavor == .owncloud && server.trash)
        #expect(c.dav.root == "/remote.php/dav/files/\(self.server.user)")
        #expect(c.dav.capabilities.contains(.trash) && c.dav.capabilities.contains(.setDates))
        #expect(c.dav.canShareLinks)
    }

    @Test func uploadsInChunksWithDateAndChecksum() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        let src = local.appendingPathComponent("big.bin")
        let data = randomData(23 * mb + 11)
        try data.write(to: src)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: src.path)
        _ = try await engine(c.registry).transferFile(.local(src.path), to: folder.appending("big.bin"), mode: .copy, LocalProvider(), c.dav)
        #expect(try await c.dav.metadata(of: folder.appending("big.bin")).modified?.tv_sec == 1_600_000_000)
        #expect(try await contents(c, folder.appending("big.bin")) == data)
        var names: [String] = []
        for try await batch in c.dav.list(folder) { names += batch.map(\.name) }
        #expect(names == ["big.bin"])
        // Dates of items already there are set too.
        _ = try await c.dav.applyMetadata(FileMetadata(modified: timespec(tv_sec: 1_500_000_000, tv_nsec: 0)), to: folder.appending("big.bin"))
        #expect(try await c.dav.metadata(of: folder.appending("big.bin")).modified?.tv_sec == 1_500_000_000)
    }

    @Test func trashAndPermanentDelete() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        for name in ["keep.txt", "gone.txt"] {
            try Data(name.utf8).write(to: local.appendingPathComponent(name))
            _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent(name).path),
                                                          to: folder.appending(name), mode: .copy, LocalProvider(), c.dav)
        }
        try await c.dav.trash(folder.appending("keep.txt"))
        try await c.dav.remove(folder.appending("gone.txt"))
        let oc = try #require(c.dav.nextcloud)
        let response = try await c.dav.send("PROPFIND", c.dav.url(server: oc.trashBin, folder: true), headers: ["Depth": "1"],
                                            body: DAVXML.propfind(nextcloud: false, extra: [("oc", "trashbin-original-location")]))
        let places = try DAVXML.parse(response.body).compactMap { $0.value(DAVNamespace.owncloud, "trashbin-original-location") }
        let relative = String(folder.path.dropFirst())
        #expect(places.contains(relative + "/keep.txt"))
        #expect(!places.contains(relative + "/gone.txt"))
    }

    @Test func copyLinkMakesAndReusesAPublicLink() async throws {
        let (c, folder) = try await connect()
        defer { Task { await c.close() } }
        let local = try scratch()
        try Data("shared".utf8).write(to: local.appendingPathComponent("s.txt"))
        _ = try await engine(c.registry).transferFile(.local(local.appendingPathComponent("s.txt").path),
                                                      to: folder.appending("s.txt"), mode: .copy, LocalProvider(), c.dav)
        let link = try await c.dav.sharedLink(for: folder.appending("s.txt"), lifetime: nil)
        #expect(link.path.contains("/s/"))
        #expect(try await c.dav.sharedLink(for: folder.appending("s.txt"), lifetime: nil) == link)
        let (body, response) = try await URLSession(configuration: .ephemeral).data(from: link.appendingPathComponent("download"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("shared".utf8))
    }
}

/// Paths and the multistatus parser, on what servers send.
@Suite struct WebDAVParsingTests {
    @Test func pathsAreEncodedAndDecoded() {
        #expect(DAVPath.encode("/a b/é+x") == "/a%20b/%C3%A9%2Bx")
        #expect(DAVPath.decode("http://h:8/dav/a%20b/") == "/dav/a b")
        #expect(DAVPath.decode("/dav/") == "/dav")
        #expect(DAVPath.decode("/") == "")
        #expect(DAVPath.normalized("dav/") == "/dav")
        #expect(DAVPath.normalized(nil) == "")
        #expect(DAVPath.parent("/a/b") == "/a")
        #expect(DAVPath.parent("/a") == "")
        #expect(DAVPath.parent("") == nil)
    }

    @Test func multistatusKeepsOnlyFoundProperties() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response><d:href>/f/a.txt</d:href>
        <d:propstat><d:prop><d:getcontentlength>12</d:getcontentlength><d:getlastmodified>Sun, 13 Sep 2020 12:26:40 GMT</d:getlastmodified>
        <d:getetag>"abc"</d:getetag><d:resourcetype/><oc:fileid>80</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:creationdate/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        <d:response><d:href>/f/sub/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """
        let entries = try DAVXML.parse(Data(xml.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].size == 12 && entries[0].etag == "\"abc\"" && entries[0].fileID == "80" && !entries[0].isCollection)
        #expect(entries[0].modified == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(entries[1].isCollection && entries[1].href == "/f/sub/")
    }
}
