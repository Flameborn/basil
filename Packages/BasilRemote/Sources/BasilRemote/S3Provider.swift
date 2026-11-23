import BasilCore
import BasilVFS
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Buckets and objects of an S3 service (Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO,
/// ...). "/" lists the buckets; "/photos/2026/a.jpg" is the key "2026/a.jpg" in the bucket
/// photos. S3 has no folders: a folder is a key prefix ending in "/", shown when any key starts
/// with it, and F7 makes an empty "name/" object so a new folder shows before it holds files
/// (like Cyberduck). A folder whose last file is removed and that has no such object is gone.
///
/// Objects appear whole: a PUT or a finished multipart upload, never half-written. Every body
/// is signed with its SHA-256, so the server refuses data changed on the way, and after each
/// upload its size is checked. Renames and moves are server-side copies followed by deletes
/// (not atomic: a folder is renamed object by object). File dates are kept in the object's
/// x-amz-meta-mtime (rclone's convention); listings show when S3 stored the object.
/// Fingerprints carry the ETag, which changes with the content.
public final class S3Provider: WritableProvider, ConnectedProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let service: S3Service
    /// Buckets the connection may use when the keys cannot list buckets (from the Start folder).
    let knownBuckets: [String]
    /// Files created and not yet uploaded: until the upload ends they do not exist.
    let uncommitted = Mutex<Set<String>>([])
    /// Dates of partial files uploaded without one (multipart uploads take their metadata at the
    /// start); the rename into place stores it.
    let pendingDates = Mutex<[String: Int]>([:])

    /// Largest object a single copy request copies; larger ones are copied in parts.
    static let copyLimit: Int64 = 5 << 30
    static let copyPartSize: Int64 = 512 << 20

    public var connectionTitle: String { service.endpoint.account }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/") }
    public var capabilities: ProviderCapabilities { [.read, .write, .randomAccessRead, .rename, .clone, .setDates] }

    init(service: S3Service, knownBuckets: [String]) {
        self.service = service
        self.knownBuckets = knownBuckets
        location = ProviderLocation(provider: .s3, instance: service.endpoint.account)
    }

    public func disconnect() async { service.close() }

    var host: String { service.endpoint.hostAndPort }

    // MARK: Paths

    /// Bucket and key of a path; nil for "/". The key is "" for a bucket itself.
    func split(_ path: VFSPath) -> (bucket: String, key: String)? {
        let parts = path.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let bucket = parts.first else { return nil }
        return (String(bucket), parts.count > 1 ? String(parts[1]) : "")
    }

    func path(bucket: String, key: String) -> VFSPath {
        var key = key
        while key.hasSuffix("/") { key.removeLast() }
        return VFSPath(location: location, path: "/" + bucket + (key.isEmpty ? "" : "/" + key))
    }

    // MARK: Calls

    func send(_ method: String, bucket: String?, key: String = "", query: [(String, String)] = [],
              headers: [String: String] = [:], body: Data? = nil, retry: Bool = true) async throws -> HTTPResponse {
        do {
            return try await service.send(method, bucket: bucket, key: key, query: query, headers: headers, body: body, retry: retry)
        } catch is HTTPUnauthorized {
            throw VFSError.failed("\(host) no longer accepts the keys. Disconnect and connect again.")
        } catch is UntrustedCertificate {
            throw VFSError.failed("The TLS certificate of \(host) changed while connected. Connect again to check it.")
        }
    }

    /// A refused request in VFS terms.
    func failure(_ response: HTTPResponse, _ action: String, _ path: VFSPath) -> Error {
        let error = S3ErrorBody(response.body)
        switch (response.status, error?.code ?? "") {
        case (_, "NoSuchKey"), (_, "NoSuchBucket"), (404, _), (410, _): return VFSError.notFound(path)
        case (_, "BucketNotEmpty"): return VFSError.directoryNotEmpty(path)
        case (_, "BucketAlreadyOwnedByYou"), (_, "BucketAlreadyExists"): return VFSError.alreadyExists(path)
        case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"):
            return VFSError.failed("\(action) failed: \(host) no longer accepts the keys (\(error?.message ?? ""))")
        case (_, "AccessDenied"), (403, _): return VFSError.permissionDenied(path)
        case (_, "EntityTooLarge"): return VFSError.failed("\(action) failed: \(host) does not take files this large")
        default:
            if let error {
                let message = error.message.isEmpty ? error.code : "\(error.message) (\(error.code))"
                return VFSError.failed("\(action) failed: \(message)")
            }
            return VFSError.failed("\(action) failed: HTTP \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))")
        }
    }

    /// An object's headers (HEAD), or nil when there is no such object.
    func head(_ bucket: String, _ key: String, _ path: VFSPath) async throws -> HTTPResponse? {
        let response = try await send("HEAD", bucket: bucket, key: key)
        if response.status == 404 { return nil }
        guard response.isSuccess else { throw failure(response, "Reading \(path.displayName)", path) }
        return response
    }

    /// What is at a path: a file (with its headers), a folder, or nothing.
    enum Found {
        case file(HTTPResponse)
        case folder
    }

    func find(_ path: VFSPath) async throws -> Found? {
        guard let (bucket, key) = split(path) else { return .folder }
        if key.isEmpty {
            let response = try await send("HEAD", bucket: bucket)
            if response.status == 404 { return nil }
            if response.isSuccess || response.status == 403 { return .folder }
            throw failure(response, "Reading \(path.displayName)", path)
        }
        if let response = try await head(bucket, key, path) { return .file(response) }
        let listing = try await listObjects(bucket, prefix: key + "/", delimiter: nil, maxKeys: 1, path: path)
        return listing.objects.isEmpty && listing.prefixes.isEmpty ? nil : .folder
    }

    struct Listing {
        struct Object {
            var key: String
            var size: Int64
            var modified: Date?
            var etag: String?
        }

        var objects: [Object] = []
        var prefixes: [String] = []
        var next: String?
    }

    /// One page of ListObjectsV2.
    func listObjects(_ bucket: String, prefix: String, delimiter: String?, maxKeys: Int? = nil,
                     continuation: String? = nil, path: VFSPath) async throws -> Listing {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("encoding-type", "url")]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let maxKeys { query.append(("max-keys", String(maxKeys))) }
        if let continuation { query.append(("continuation-token", continuation)) }
        let response = try await send("GET", bucket: bucket, query: query)
        guard response.isSuccess else { throw failure(response, "Listing \(path.displayName)", path) }
        guard let root = XMLNode.parse(response.body), root.name == "ListBucketResult" else {
            throw VFSError.failed("\(host) sent an unreadable listing of \(path.displayName)")
        }
        let encoded = root.value("EncodingType") == "url"
        func decode(_ text: String) -> String {
            guard encoded else { return text }
            let spaced = text.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        var listing = Listing()
        for object in root.all("Contents") {
            guard let key = object.value("Key") else { continue }
            listing.objects.append(Listing.Object(
                key: decode(key), size: Int64(object.value("Size") ?? "") ?? 0,
                modified: object.value("LastModified").flatMap(S3Dates.iso),
                etag: object.value("ETag")))
        }
        for common in root.all("CommonPrefixes") {
            if let prefix = common.value("Prefix") { listing.prefixes.append(decode(prefix)) }
        }
        if root.value("IsTruncated") == "true" { listing.next = root.value("NextContinuationToken") }
        return listing
    }

    /// Every object under a prefix, all pages.
    func allObjects(_ bucket: String, prefix: String, path: VFSPath) async throws -> [Listing.Object] {
        var result: [Listing.Object] = []
        var next: String?
        repeat {
            let page = try await listObjects(bucket, prefix: prefix, delimiter: nil, continuation: next, path: path)
            result += page.objects
            next = page.next
        } while next != nil
        return result
    }

    func fileItem(_ path: VFSPath, _ response: HTTPResponse) -> FileItem {
        FileItem(path: path, kind: .file, size: Int64(response.header("Content-Length") ?? "") ?? 0,
                 modified: response.header("Last-Modified").flatMap(S3Dates.http),
                 isHidden: path.name.hasPrefix("."), fileID: response.header("ETag").map(WebDAVProvider.number))
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let (bucket, key) = split(directory) {
                        try await listFolder(bucket, key, directory, continuation)
                    } else {
                        continuation.yield(try await listBuckets(directory))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func listBuckets(_ root: VFSPath) async throws -> [FileItem] {
        let response = try await send("GET", bucket: nil)
        if !response.isSuccess, S3ErrorBody(response.body)?.code == "AccessDenied" || response.status == 403, !knownBuckets.isEmpty {
            // Keys limited to some buckets: show the ones the Start folder named.
            return knownBuckets.map { FileItem(path: path(bucket: $0, key: ""), kind: .directory) }
        }
        guard response.isSuccess else {
            if response.status == 403 {
                throw VFSError.failed("\(host) does not let these keys list the buckets. Put the bucket in the connection's Start folder (for example /photos).")
            }
            throw failure(response, "Listing the buckets", root)
        }
        guard let xml = XMLNode.parse(response.body), xml.name == "ListAllMyBucketsResult" else {
            throw VFSError.failed("\(host) sent an unreadable list of buckets")
        }
        return (xml.child("Buckets")?.all("Bucket") ?? []).compactMap { bucket in
            guard let name = bucket.value("Name") else { return nil }
            return FileItem(path: path(bucket: name, key: ""), kind: .directory,
                            modified: bucket.value("CreationDate").flatMap(S3Dates.iso))
        }
    }

    private func listFolder(_ bucket: String, _ key: String, _ directory: VFSPath,
                            _ continuation: AsyncThrowingStream<[FileItem], Error>.Continuation) async throws {
        let prefix = key.isEmpty ? "" : key + "/"
        var next: String?
        var first = true
        repeat {
            let page = try await listObjects(bucket, prefix: prefix, delimiter: "/", continuation: next, path: directory)
            if first, !key.isEmpty, page.objects.isEmpty, page.prefixes.isEmpty, page.next == nil {
                // Nothing under the prefix: a file of that name, or nothing at all.
                if try await head(bucket, key, directory) != nil { throw VFSError.notADirectory(directory) }
                throw VFSError.notFound(directory)
            }
            first = false
            var batch: [FileItem] = []
            for prefix in page.prefixes {
                let name = String(prefix.dropFirst(key.isEmpty ? 0 : key.count + 1).dropLast())
                guard !name.isEmpty, !name.contains("/") else { continue }
                batch.append(FileItem(path: directory.appending(name), kind: .directory, isHidden: name.hasPrefix(".")))
            }
            for object in page.objects {
                // The folder's own "name/" object.
                guard object.key != prefix else { continue }
                let name = String(object.key.dropFirst(prefix.count))
                guard !name.isEmpty, !name.contains("/") else { continue }
                batch.append(FileItem(path: directory.appending(name), kind: .file, size: object.size,
                                      modified: object.modified, isHidden: name.hasPrefix("."),
                                      fileID: object.etag.map(WebDAVProvider.number)))
            }
            if !batch.isEmpty { continuation.yield(batch) }
            next = page.next
        } while next != nil
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        switch try await find(path) {
        case .file(let response): return fileItem(path, response)
        case .folder: return FileItem(path: path, kind: .directory, isHidden: path.name.hasPrefix("."))
        case nil: throw VFSError.notFound(path)
        }
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        switch try await find(path) {
        case .file(let response):
            let nanos = response.header("Last-Modified").flatMap(S3Dates.http)
                .map { Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded()) }
            return FileFingerprint(kind: .file, size: Int64(response.header("Content-Length") ?? "") ?? 0,
                                   modifiedNanos: nanos, fileID: response.header("ETag").map(WebDAVProvider.number))
        case .folder: return FileFingerprint(kind: .directory, size: 0)
        case nil: throw VFSError.notFound(path)
        }
    }

    /// The stored date (x-amz-meta-mtime), else when S3 stored the object.
    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        guard case .file(let response) = try await find(path) else { return FileMetadata() }
        var metadata = FileMetadata()
        if let seconds = Self.storedDate(response) {
            metadata.modified = timespec(tv_sec: seconds, tv_nsec: 0)
        } else if let date = response.header("Last-Modified").flatMap(S3Dates.http) {
            metadata.modified = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        }
        return metadata
    }

    static func storedDate(_ response: HTTPResponse) -> Int? {
        response.header("x-amz-meta-mtime").flatMap(Double.init).map { Int($0.rounded(.down)) }
    }

    /// Stores a file's date by copying the object onto itself with new metadata (server-side).
    /// Folders and everything else are left out quietly, as on FTP servers.
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        guard let modified = metadata.modified, let (bucket, key) = split(path), !key.isEmpty,
              case .file(let response) = try await find(path) else { return [] }
        if Self.storedDate(response) == modified.tv_sec { return [] }
        do {
            try await copyObject(from: (bucket, key), to: (bucket, key), size: Int64(response.header("Content-Length") ?? "") ?? 0,
                                 date: modified.tv_sec, source: response, path: path)
            return []
        } catch {
            return ["could not store the date (\(error.localizedDescription))"]
        }
    }

    /// Server-side copies work inside one bucket.
    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        "s3:" + service.endpoint.account + "/" + (split(path)?.bucket ?? "")
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        guard let (bucket, key) = split(path), !key.isEmpty, case .file = try await find(path) else {
            throw VFSError.failed("\(path.displayName) is a folder")
        }
        let service = service
        return HTTPReadFile(name: path.name, start: { service.download(bucket: bucket, key: key, from: $0) },
                            currentSize: { try? await self.head(bucket, key, path).flatMap { Int64($0.header("Content-Length") ?? "") } },
                            failure: { self.failure($0, "Reading \(path.name)", path) })
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        guard let (bucket, key) = split(path), !key.isEmpty else { throw VFSError.alreadyExists(path) }
        if try await find(path) != nil { throw VFSError.alreadyExists(path) }
        uncommitted.withLock { _ = $0.insert(path.path) }
        return S3WriteFile(path: path, bucket: bucket, key: key, provider: self)
    }

    /// A copy then a delete. A folder is renamed object by object.
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        guard let (bucket, key) = split(from), !key.isEmpty else { throw VFSError.unsupported("renaming buckets") }
        guard let (toBucket, toKey) = split(to), !toKey.isEmpty else { throw VFSError.alreadyExists(to) }
        let found = try await find(from)
        let existing = try await find(to)
        switch found {
        case nil:
            throw VFSError.notFound(from)
        case .file(let response):
            if case .folder = existing { throw VFSError.alreadyExists(to) }
            if existing != nil, !replacing { throw VFSError.alreadyExists(to) }
            let date = pendingDates.withLock { $0.removeValue(forKey: from.path) }
            try await copyObject(from: (bucket, key), to: (toBucket, toKey), size: Int64(response.header("Content-Length") ?? "") ?? 0,
                                 date: date, source: response, path: from)
            try await deleteObject(bucket, key, from)
        case .folder:
            if existing != nil { throw VFSError.alreadyExists(to) }
            let objects = try await allObjects(bucket, prefix: key + "/", path: from)
            try await forEach(objects) { object in
                let rest = String(object.key.dropFirst(key.count))
                try await self.copyObject(from: (bucket, object.key), to: (toBucket, toKey + rest), size: object.size,
                                          date: nil, source: nil, path: from)
            }
            try await forEach(objects) { object in try await self.deleteObject(bucket, object.key, from) }
        }
    }

    /// Runs `work` for every object, eight at a time.
    private func forEach(_ objects: [Listing.Object], _ work: @escaping @Sendable (Listing.Object) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for object in objects {
                if running == 8 {
                    try await group.next()
                    running -= 1
                }
                group.addTask { try await work(object) }
                running += 1
            }
            try await group.waitForAll()
        }
    }

    /// A server-side copy of a file (the target must not exist).
    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        guard let (bucket, key) = split(from), !key.isEmpty, let (toBucket, toKey) = split(to), !toKey.isEmpty else {
            throw VFSError.unsupported("copying buckets")
        }
        guard case .file(let response) = try await find(from) else { throw VFSError.unsupported("copying folders on \(host)") }
        if try await find(to) != nil { throw VFSError.alreadyExists(to) }
        try await copyObject(from: (bucket, key), to: (toBucket, toKey), size: Int64(response.header("Content-Length") ?? "") ?? 0,
                             date: nil, source: response, path: from)
    }

    /// Copies an object on the server. `date` replaces its stored date (keeping its content
    /// type); nil keeps its metadata. Objects over 5 GB are copied in parts.
    func copyObject(from: (String, String), to: (String, String), size: Int64, date: Int?,
                    source: HTTPResponse?, path: VFSPath) async throws {
        let action = "Copying \(path.name)"
        let copySource = "/" + S3Signer.encode(from.0) + "/" + S3Signer.encode(from.1, keepSlash: true)
        var metadata: [String: String] = [:]
        if let date {
            metadata["x-amz-meta-mtime"] = String(date)
            if let type = source?.header("Content-Type") { metadata["Content-Type"] = type }
        }
        if size <= Self.copyLimit {
            var headers = metadata
            headers["x-amz-copy-source"] = copySource
            headers["x-amz-metadata-directive"] = date == nil ? "COPY" : "REPLACE"
            let response = try await send("PUT", bucket: to.0, key: to.1, headers: headers)
            // A copy can fail after its 200 began: the error is then in the body.
            if !response.isSuccess || S3ErrorBody(response.body) != nil { throw failure(response, action, path) }
            return
        }
        // Large: a multipart upload made of copied ranges, with the source's metadata (or the new date).
        var headers = metadata
        if date == nil, let source {
            for (name, value) in source.headers where name.hasPrefix("x-amz-meta-") || name == "content-type" {
                headers[name] = value
            }
        }
        let upload = try await startMultipart(to.0, to.1, headers: headers, action: action, path: path)
        do {
            var parts: [String] = []
            var offset: Int64 = 0
            while offset < size {
                let end = min(offset + Self.copyPartSize, size) - 1
                let response = try await send("PUT", bucket: to.0, key: to.1,
                                              query: [("partNumber", String(parts.count + 1)), ("uploadId", upload)],
                                              headers: ["x-amz-copy-source": copySource, "x-amz-copy-source-range": "bytes=\(offset)-\(end)"])
                guard response.isSuccess, let xml = XMLNode.parse(response.body), let etag = xml.value("ETag") else {
                    throw failure(response, action, path)
                }
                parts.append(etag)
                offset = end + 1
            }
            try await completeMultipart(to.0, to.1, upload: upload, parts: parts, action: action, path: path)
        } catch {
            await abortMultipart(to.0, to.1, upload: upload)
            throw error
        }
    }

    func startMultipart(_ bucket: String, _ key: String, headers: [String: String], action: String, path: VFSPath) async throws -> String {
        let response = try await send("POST", bucket: bucket, key: key, query: [("uploads", "")], headers: headers)
        guard response.isSuccess, let xml = XMLNode.parse(response.body), let id = xml.value("UploadId") else {
            throw failure(response, action, path)
        }
        return id
    }

    func completeMultipart(_ bucket: String, _ key: String, upload: String, parts: [String], action: String, path: VFSPath) async throws {
        var body = "<CompleteMultipartUpload>"
        for (index, etag) in parts.enumerated() {
            let escaped = etag.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            body += "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(escaped)</ETag></Part>"
        }
        body += "</CompleteMultipartUpload>"
        let response = try await send("POST", bucket: bucket, key: key, query: [("uploadId", upload)],
                                      headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
        if !response.isSuccess || S3ErrorBody(response.body) != nil { throw failure(response, action, path) }
    }

    func abortMultipart(_ bucket: String, _ key: String, upload: String) async {
        _ = try? await send("DELETE", bucket: bucket, key: key, query: [("uploadId", upload)])
    }

    func deleteObject(_ bucket: String, _ key: String, _ path: VFSPath) async throws {
        let response = try await send("DELETE", bucket: bucket, key: key)
        guard response.isSuccess || response.status == 404 else { throw failure(response, "Deleting \(path.name)", path) }
    }

    /// Removes a file, an empty folder (its "name/" object) or an empty bucket. A folder that
    /// exists only because of the files in it is gone once they are, so removing it again is
    /// fine.
    public func remove(_ path: VFSPath) async throws {
        guard let (bucket, key) = split(path) else { throw VFSError.permissionDenied(path) }
        if key.isEmpty {
            let response = try await send("DELETE", bucket: bucket)
            guard response.isSuccess else { throw failure(response, "Deleting the bucket \(bucket)", path) }
            return
        }
        // A partial file the copy engine writes again from the start was never uploaded.
        if uncommitted.withLock({ $0.remove(path.path) }) != nil, try await head(bucket, key, path) == nil { return }
        pendingDates.withLock { _ = $0.removeValue(forKey: path.path) }
        if try await head(bucket, key, path) != nil {
            try await deleteObject(bucket, key, path)
            return
        }
        let inside = try await listObjects(bucket, prefix: key + "/", delimiter: nil, maxKeys: 2, path: path)
        if inside.objects.contains(where: { $0.key != key + "/" }) || !inside.prefixes.isEmpty {
            throw VFSError.directoryNotEmpty(path)
        }
        if inside.objects.contains(where: { $0.key == key + "/" }) { try await deleteObject(bucket, key + "/", path) }
    }

    /// A bucket at the top (in the connection's region), else an empty "name/" object.
    public func makeDirectory(_ path: VFSPath) async throws {
        guard let (bucket, key) = split(path) else { throw VFSError.alreadyExists(path) }
        if key.isEmpty {
            var body: Data?
            let region = service.defaultRegion
            if service.endpoint.isAWS, region != "us-east-1" {
                body = Data("<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>".utf8)
            }
            let response = try await send("PUT", bucket: bucket, body: body, retry: false)
            guard response.isSuccess else { throw failure(response, "Making the bucket \(bucket)", path) }
            service.learn(region: region, for: bucket)
            return
        }
        if try await find(path) != nil { throw VFSError.alreadyExists(path) }
        let response = try await send("PUT", bucket: bucket, key: key + "/", body: Data())
        guard response.isSuccess else { throw failure(response, "Making \(path.name)", path) }
    }

    /// S3 has stored an object once it answered.
    public func synchronize(_ path: VFSPath) async throws {}

    public func readSymlink(_ path: VFSPath) async throws -> String {
        throw VFSError.unsupported("links on \(host)")
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links on \(host)")
    }

    /// The content type S3 serves a file with, from its extension.
    static func contentType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
