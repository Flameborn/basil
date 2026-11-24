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
    func callAsFunction(_ body: () async throws -> Void) async rethrows {
        if !done.exchange(true, ordering: .relaxed) { try await body() }
    }
}

private final class Monitor: TransferMonitor {
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) {}
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}

private func engine(_ registry: ProviderRegistry, secure: Bool = true,
                    afterChunk: (@Sendable (Int, Int) async -> Void)? = nil) -> SecureCopyEngine {
    SecureCopyEngine(registry: registry, options: SecureCopyOptions(retryDelay: .milliseconds(1), secure: secure),
                     monitor: Monitor(), hooks: EngineHooks(afterChunk: afterChunk, afterClone: nil, allowed: [.rename, .clone, .stream]))
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-s3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Signing, AWS profiles and region names, without a server.
struct S3SigningTests {
    let credentials = S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    /// The examples of AWS's "Signature Calculations for the Authorization Header" page.
    @Test func getObjectExample() {
        let headers = S3Signer.sign(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", query: "",
                                    headers: ["Range": "bytes=0-9"], payloadHash: S3Signer.emptyHash,
                                    credentials: credentials, region: "us-east-1", date: date)
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func listObjectsExample() {
        let query = S3Signer.query([("prefix", "J"), ("max-keys", "2")])
        #expect(query == "max-keys=2&prefix=J")
        let headers = S3Signer.sign(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/", query: query,
                                    headers: [:], payloadHash: S3Signer.emptyHash,
                                    credentials: credentials, region: "us-east-1", date: date)
        #expect(headers["Authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    /// The example of AWS's "Authenticating Requests: Using Query Parameters" page.
    @Test func presignedURLExample() {
        let url = S3Signer.presignedURL(scheme: "https", host: "examplebucket.s3.amazonaws.com", path: "/test.txt",
                                        credentials: credentials, region: "us-east-1", expires: 86_400, date: date)
        #expect(url.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func encodesLikeSigV4() {
        #expect(S3Signer.encode("a b/é+~", keepSlash: true) == "a%20b/%C3%A9%2B~")
        #expect(S3Signer.encode("a/b") == "a%2Fb")
        #expect(S3Signer.query([("uploads", "")]) == "uploads=")
    }

    @Test func regionsFromHosts() {
        #expect(S3Endpoint.region(fromHost: "s3.amazonaws.com") == "us-east-1")
        #expect(S3Endpoint.region(fromHost: "s3.eu-central-1.amazonaws.com") == "eu-central-1")
        #expect(S3Endpoint.region(fromHost: "s3.dualstack.ap-south-1.amazonaws.com") == "ap-south-1")
        #expect(S3Endpoint.region(fromHost: "s3-eu-west-1.amazonaws.com") == "eu-west-1")
        #expect(S3Endpoint.region(fromHost: "abc123.r2.cloudflarestorage.com") == "auto")
        #expect(S3Endpoint.region(fromHost: "s3.us-west-004.backblazeb2.com") == "us-west-004")
        #expect(S3Endpoint.region(fromHost: "s3.eu-central-1.wasabisys.com") == "eu-central-1")
        #expect(S3Endpoint.region(fromHost: "fra1.digitaloceanspaces.com") == "fra1")
        #expect(S3Endpoint.region(fromHost: "nas.local") == nil)
    }

    @Test func readsProfiles() throws {
        let home = try scratch()
        let aws = home.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: aws, withIntermediateDirectories: true)
        try """
        [default]
        aws_access_key_id = AKIDEFAULT
        aws_secret_access_key = secret1

        [r2]
        aws_access_key_id=AKIDR2
        aws_secret_access_key=secret2
        aws_session_token = token2
        """.write(to: aws.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
        try """
        [default]
        region = eu-central-1
        # a comment
        [profile r2]
        region = auto
        s3 =
          endpoint_url = https://abc.r2.cloudflarestorage.com
        [profile sso]
        sso_session = work
        """.write(to: aws.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let profiles = AWSProfiles(home: home, environment: [:])
        #expect(profiles.names() == ["default", "r2", "sso"])
        let standard = try #require(profiles.profile("default"))
        #expect(standard.accessKey == "AKIDEFAULT" && standard.secretKey == "secret1" && standard.region == "eu-central-1")
        let r2 = try #require(profiles.profile("r2"))
        #expect(r2.sessionToken == "token2" && r2.region == "auto")
        #expect(r2.endpointURL == "https://abc.r2.cloudflarestorage.com")
        #expect(profiles.profile("sso")?.unsupported == ["sso_session"])
        #expect(profiles.profile("missing") == nil)
    }
}

struct S3Connection {
    let registry: ProviderRegistry
    let s3: S3Provider
    let start: VFSPath
    let prompts: FTPPrompts
    func close() async { await registry.disconnect(start.location) }
}

/// The S3 client against the Versity S3 Gateway in Docker: logins, buckets, folders, uploads in
/// one PUT and in parts, server-side copies and renames, and the copy engine with sources that
/// change during uploads and downloads. Skipped when Docker is not running.
@Suite(.serialized, .enabled(if: S3TestServer.shared != nil))
struct S3Tests {
    var server: S3TestServer { S3TestServer.shared! }

    func connect(_ target: RemoteTarget, prompts: FTPPrompts, profiles: AWSProfiles? = nil) async throws -> S3Connection {
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let trust = FileManager.default.temporaryDirectory.appendingPathComponent("basil-trust-\(UUID().uuidString)")
        registry.register(connector: S3Connector(trustFile: trust, profiles: try profiles ?? AWSProfiles(home: scratch(), environment: [:])))
        let start = try await registry.connect(target, prompts: prompts)
        let s3 = try #require(try registry.provider(for: start.location) as? S3Provider)
        return S3Connection(registry: registry, s3: s3, start: start, prompts: prompts)
    }

    /// A connection and a fresh bucket.
    func connectWithBucket() async throws -> (S3Connection, VFSPath) {
        let c = try await connect(server.target(), prompts: FTPPrompts(secrets: [server.secretKey]))
        let bucket = VFSPath(location: c.start.location, path: "/t-" + UUID().uuidString.prefix(8).lowercased())
        try await c.s3.makeDirectory(bucket)
        return (c, bucket)
    }

    func names(_ c: S3Connection, _ path: VFSPath) async throws -> Set<String> {
        var items: [FileItem] = []
        for try await batch in c.s3.list(path) { items += batch }
        return Set(items.map(\.name))
    }

    func contents(_ c: S3Connection, _ path: VFSPath) async throws -> Data {
        let file = try await c.s3.openForReading(path, bypassCache: false)
        defer { Task { await file.close() } }
        var data = Data()
        while true {
            let part = try await file.read(at: Int64(data.count), count: 4 * mb)
            data.append(part)
            if part.count < 4 * mb { return data }
        }
    }

    /// Another client stores an object (what changes a source on the server).
    func put(_ c: S3Connection, _ path: VFSPath, _ data: Data) async throws {
        let (bucket, key) = try #require(c.s3.split(path))
        let response = try await c.s3.service.send("PUT", bucket: bucket, key: key, body: data)
        #expect(response.isSuccess)
    }

    // MARK: Connecting

    @Test func logsInAndListsBuckets() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        #expect(c.start.isRoot)
        #expect(try await names(c, c.start).contains(bucket.name))
        #expect(c.prompts.state.withLock { $0.secretRequests.map(\.keychainKey) } == ["s3:\(server.accessKey)@\(server.host):7070"])
        #expect(c.prompts.state.withLock { $0.worked } == 1)
        #expect(c.s3.connectionTitle == "\(server.accessKey)@\(server.host):7070")
    }

    @Test func wrongSecretIsAskedAgain() async throws {
        let prompts = FTPPrompts(secrets: ["wrong", server.secretKey])
        let c = try await connect(server.target(), prompts: prompts)
        #expect(prompts.state.withLock { $0.secretRequests.map(\.retry) } == [false, true])
        #expect(prompts.state.withLock { $0.secretRequests.first?.kind } == .named("Secret access key"))
        await c.close()
    }

    @Test func unknownKeyIsNotAskedAgain() async throws {
        do {
            _ = try await connect(server.target(user: "nobody"), prompts: FTPPrompts(secrets: ["x", "y"]))
            Issue.record("connected with an unknown key")
        } catch let error as VFSError {
            #expect(error.localizedDescription.contains("refused the keys"))
        }
    }

    @Test func cancelledSecretStops() async throws {
        await #expect(throws: RemoteCancelled.self) { _ = try await connect(server.target(), prompts: FTPPrompts(secrets: [nil])) }
    }

    @Test func profileLogsIn() async throws {
        let home = try scratch()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try "[test]\naws_access_key_id = \(server.accessKey)\naws_secret_access_key = \(server.secretKey)\n"
            .write(to: home.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        let prompts = FTPPrompts(secrets: [])
        let c = try await connect(server.target(user: "test", authentication: .automatic), prompts: prompts,
                                  profiles: AWSProfiles(home: home, environment: [:]))
        #expect(prompts.state.withLock { $0.secretRequests.isEmpty })
        #expect(c.s3.connectionTitle == "test@\(server.host):7070")
        await c.close()
        // Automatic with a User that names no profile: an access key ID.
        let d = try await connect(server.target(authentication: .automatic), prompts: FTPPrompts(secrets: [server.secretKey]),
                                  profiles: AWSProfiles(home: home, environment: [:]))
        await d.close()
    }

    @Test func startFolderInABucket() async throws {
        let (c, bucket) = try await connectWithBucket()
        try await c.s3.makeDirectory(bucket.appending("photos"))
        await c.close()
        let d = try await connect(server.target(path: bucket.path + "/photos"), prompts: FTPPrompts(secrets: [server.secretKey]))
        #expect(d.start.path == bucket.path + "/photos")
        #expect(d.s3.knownBuckets == [bucket.name])
        await d.close()
        await #expect(throws: VFSError.self) {
            _ = try await connect(server.target(path: bucket.path + "/missing"), prompts: FTPPrompts(secrets: [server.secretKey]))
        }
    }

    // MARK: Files and folders

    @Test func foldersFilesRenamesAndDeletes() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let folder = bucket.appending("a b é")
        try await c.s3.makeDirectory(folder)
        await #expect(throws: VFSError.alreadyExists(folder)) { try await c.s3.makeDirectory(folder) }
        #expect(try await c.s3.item(at: folder).kind == .directory)
        #expect(try await names(c, folder).isEmpty)

        let file = folder.appending("x+y.txt")
        let writer = try await c.s3.createFile(file)
        try await writer.write(Data("hello".utf8), at: 0)
        _ = try await writer.apply(FileMetadata(modified: timespec(tv_sec: 1_600_000_000, tv_nsec: 0)))
        await writer.close()
        #expect(try await names(c, bucket) == ["a b é"])
        #expect(try await names(c, folder) == ["x+y.txt"])
        let item = try await c.s3.item(at: file)
        #expect(item.kind == .file && item.size == 5)
        #expect(try await c.s3.metadata(of: file).modified?.tv_sec == 1_600_000_000)
        #expect(try await contents(c, file) == Data("hello".utf8))
        await #expect(throws: VFSError.alreadyExists(file)) { _ = try await c.s3.createFile(file) }
        await #expect(throws: VFSError.directoryNotEmpty(folder)) { try await c.s3.remove(folder) }

        // Server-side copy and rename of a file; the date goes along.
        try await c.s3.clone(file, to: folder.appending("copy.txt"))
        try await c.s3.rename(file, to: folder.appending("renamed.txt"), replacing: false)
        #expect(try await names(c, folder) == ["copy.txt", "renamed.txt"])
        #expect(try await c.s3.metadata(of: folder.appending("renamed.txt")).modified?.tv_sec == 1_600_000_000)
        await #expect(throws: VFSError.alreadyExists(folder.appending("copy.txt"))) {
            try await c.s3.rename(folder.appending("renamed.txt"), to: folder.appending("copy.txt"), replacing: false)
        }
        try await c.s3.rename(folder.appending("renamed.txt"), to: folder.appending("copy.txt"), replacing: true)
        #expect(try await names(c, folder) == ["copy.txt"])

        // A folder rename moves every object under it.
        try await c.s3.makeDirectory(folder.appending("inner"))
        try await c.s3.clone(folder.appending("copy.txt"), to: folder.appending("inner/deep.txt"))
        let moved = bucket.appending("moved")
        try await c.s3.rename(folder, to: moved, replacing: false)
        #expect(try await names(c, bucket) == ["moved"])
        #expect(try await names(c, moved) == ["copy.txt", "inner"])
        #expect(try await contents(c, moved.appending("inner/deep.txt")) == Data("hello".utf8))

        // Deleting: files, then the empty folders, then the bucket.
        try await c.s3.remove(moved.appending("inner/deep.txt"))
        try await c.s3.remove(moved.appending("inner"))
        try await c.s3.remove(moved.appending("copy.txt"))
        try await c.s3.remove(moved)
        #expect(try await names(c, bucket).isEmpty)
        try await c.s3.remove(bucket)
        #expect(try await !names(c, c.start).contains(bucket.name))
    }

    @Test func copyLinkGivesAPresignedAddressThatExpires() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let file = bucket.appending("shared file.txt")
        try await put(c, file, Data("shared".utf8))
        #expect(c.s3.linkLifetimes == [.hour, .day, .week])
        let link = try await c.s3.sharedLink(for: file, lifetime: .hour)
        let (body, response) = try await URLSession(configuration: .ephemeral).data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("shared".utf8))

        let short = try await c.s3.sharedLink(for: file, lifetime: LinkLifetime(seconds: 1, title: "1 second"))
        try await Task.sleep(for: .seconds(2.5))
        let (_, expired) = try await URLSession(configuration: .ephemeral).data(from: short)
        #expect((expired as? HTTPURLResponse)?.statusCode == 403)
        await #expect(throws: VFSError.self) { _ = try await c.s3.sharedLink(for: bucket, lifetime: .hour) }
        await #expect(throws: VFSError.notFound(bucket.appending("missing"))) {
            _ = try await c.s3.sharedLink(for: bucket.appending("missing"), lifetime: .hour)
        }
    }

    @Test func readsAtOffsets() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let data = randomData(3 * mb + 17)
        try await put(c, bucket.appending("r.bin"), data)
        let file = try await c.s3.openForReading(bucket.appending("r.bin"), bypassCache: false)
        #expect(try await file.read(at: Int64(2 * mb), count: 100) == data[(2 * mb)..<(2 * mb + 100)])
        #expect(try await file.read(at: 10, count: 10) == data[10..<20])
        #expect(try await file.read(at: Int64(data.count - 7), count: 100) == data.suffix(7))
        #expect(try await file.read(at: Int64(data.count), count: 100).isEmpty)
        await file.close()
    }

    @Test(arguments: [false, true])
    func uploadsAndDownloadsThroughTheEngine(_ secure: Bool) async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let local = try scratch()
        let tree = local.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner/empty"), withIntermediateDirectories: true)
        let small = randomData(1000)
        let big = randomData(40 * mb + 3) // three parts
        try small.write(to: tree.appendingPathComponent("small.txt"))
        try big.write(to: tree.appendingPathComponent("inner/big.bin"))
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: tree.appendingPathComponent("inner/big.bin").path)

        _ = try await engine(c.registry, secure: secure).transfer(.local(tree.path), to: bucket.appending("tree"), mode: .copy)
        #expect(try await names(c, bucket.appending("tree")) == ["small.txt", "inner"])
        #expect(try await names(c, bucket.appending("tree/inner")) == ["big.bin", "empty"])
        #expect(try await contents(c, bucket.appending("tree/inner/big.bin")) == big)
        #expect(try await c.s3.metadata(of: bucket.appending("tree/inner/big.bin")).modified?.tv_sec == 1_500_000_000)
        #expect(c.s3.pendingDates.withLock { $0.isEmpty })

        // Inside the bucket: a server-side copy.
        _ = try await engine(c.registry, secure: secure).transfer(bucket.appending("tree"), to: bucket.appending("copy"), mode: .copy)
        #expect(try await contents(c, bucket.appending("copy/inner/big.bin")) == big)

        let back = local.appendingPathComponent("back")
        _ = try await engine(c.registry, secure: secure).transfer(bucket.appending("tree"), to: .local(back.path), mode: .move)
        #expect(try Data(contentsOf: back.appendingPathComponent("inner/big.bin")) == big)
        #expect(try Data(contentsOf: back.appendingPathComponent("small.txt")) == small)
        let attributes = try FileManager.default.attributesOfItem(atPath: back.appendingPathComponent("inner/big.bin").path)
        #expect((attributes[.modificationDate] as? Date) == date)
        #expect(try await !names(c, bucket).contains("tree"))
    }

    @Test func moveInsideABucketRenames() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        try await put(c, bucket.appending("m.txt"), Data("m".utf8))
        try await c.s3.makeDirectory(bucket.appending("to"))
        let result = try await engine(c.registry).transferFile(bucket.appending("m.txt"), to: bucket.appending("to/m.txt"),
                                                               mode: .move, c.s3, c.s3)
        #expect(result.strategy == .rename)
        #expect(try await names(c, bucket.appending("to")) == ["m.txt"])
        #expect(try await names(c, bucket) == ["to"])
    }

    @Test func unfinishedUploadLeavesNothing() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let writer = try await c.s3.createFile(bucket.appending("half.bin"))
        try await writer.write(randomData(20 * mb), at: 0)
        await writer.close()
        try await c.s3.remove(bucket.appending("half.bin"))
        #expect(try await names(c, bucket).isEmpty)
    }

    // A local source changing during an upload: S3 cannot write at offsets, so the partial file
    // is written again from the start. 20 MB: a multipart upload.

    func upload(_ change: @escaping @Sendable (URL) -> Void) async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(20 * mb).write(to: src)
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 2 { await once { change(src) } }
        }
        let result = try await copy.transferFile(.local(src.path), to: bucket.appending("a.bin"), mode: .copy, LocalProvider(), c.s3)
        #expect(result.retries == 1)
        #expect(try await contents(c, bucket.appending("a.bin")) == Data(contentsOf: src))
        #expect(try await names(c, bucket) == ["a.bin"])
    }

    /// Secure uploads write straight at the final key (no partial object, no copy into place):
    /// the old object stays readable until the new one is committed, and a cancelled upload
    /// leaves it as it was.
    @Test func secureUploadReplacesInPlaceAndKeepsTheOldObjectUntilCommitted() async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let path = bucket.appending("a.bin")
        let old = randomData(1000)
        try await put(c, path, old)
        let src = try scratch().appendingPathComponent("a.bin")
        try randomData(20 * mb).write(to: src)
        let seen = Mutex<[Data]>([])
        let replacing = SecureCopyEngine(registry: c.registry,
                                         options: SecureCopyOptions(retryDelay: .milliseconds(1), replaceExisting: true, secure: true),
                                         monitor: Monitor(), hooks: EngineHooks(afterChunk: { pass, index in
            if index == 1, let now = try? await contents(c, path) { seen.withLock { $0.append(now) } }
        }, afterClone: nil, allowed: [.rename, .clone, .stream]))
        _ = try await replacing.transferFile(.local(src.path), to: path, mode: .copy, LocalProvider(), c.s3)
        #expect(seen.withLock { $0 } == [old])
        #expect(try await contents(c, path) == Data(contentsOf: src))
        #expect(try await names(c, bucket) == ["a.bin"])

        // Cancelled halfway: the object is still the last committed one.
        let before = try await contents(c, path)
        try randomData(20 * mb).write(to: src)
        let cancelling = SecureCopyEngine(registry: c.registry,
                                          options: SecureCopyOptions(retryDelay: .milliseconds(1), replaceExisting: true, secure: true),
                                          monitor: Monitor(), hooks: EngineHooks(afterChunk: { _, index in
            if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }, afterClone: nil, allowed: [.rename, .clone, .stream]))
        await #expect(throws: CancellationError.self) {
            _ = try await cancelling.transferFile(.local(src.path), to: path, mode: .copy, LocalProvider(), c.s3)
        }
        #expect(try await contents(c, path) == before)
        #expect(try await names(c, bucket) == ["a.bin"])
    }

    @Test func localSourceAppendedDuringUpload() async throws {
        try await upload { src in
            let h = try! FileHandle(forWritingTo: src)
            try! h.seekToEnd(); try! h.write(contentsOf: randomData(mb + 3)); try! h.close()
        }
    }

    @Test func localSourceTruncatedDuringUpload() async throws {
        try await upload { src in Darwin.truncate(src.path, off_t(5 * mb + 1000)) }
    }

    @Test func localSourceRewrittenInTheMiddleDuringUpload() async throws {
        try await upload { src in
            let h = try! FileHandle(forWritingTo: src)
            try! h.seek(toOffset: UInt64(mb + mb / 2)); try! h.write(contentsOf: randomData(1000)); try! h.close()
        }
    }

    // A source on the server replaced during a download (objects change whole): the ETag changes.

    func download(size: Int, replacement: Data) async throws {
        let (c, bucket) = try await connectWithBucket()
        defer { Task { await c.close() } }
        let path = bucket.appending("r.bin")
        try await put(c, path, randomData(size))
        let once = Once()
        let copy = engine(c.registry) { pass, index in
            if pass == 0, index == 0 { await once { try? await put(c, path, replacement) } }
        }
        let target = try scratch().appendingPathComponent("r.bin")
        let result = try await copy.transferFile(path, to: .local(target.path), mode: .copy, c.s3, LocalProvider())
        #expect(result.retries >= 1)
        #expect(try Data(contentsOf: target) == replacement)
    }

    @Test func remoteSourceAppendedDuringDownload() async throws {
        try await download(size: 3 * mb + 100, replacement: randomData(4 * mb + 100))
    }

    @Test func remoteSourceTruncatedDuringDownload() async throws {
        try await download(size: 4 * mb, replacement: randomData(2 * mb + 5))
    }

    @Test func remoteSourceRewrittenInTheMiddleDuringDownload() async throws {
        try await download(size: 3 * mb, replacement: randomData(3 * mb))
    }
}
