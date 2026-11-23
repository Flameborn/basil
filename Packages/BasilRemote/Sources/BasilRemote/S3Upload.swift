import BasilCore
import BasilVFS
import Foundation

/// The copy engine's partial file on S3, written from the start (S3 has no random-access
/// writes). Up to `partSize` bytes it stays in memory and goes up in one PUT; a larger file
/// becomes a multipart upload of `partSize` parts (every part but the last the same size, which
/// Cloudflare R2 needs), each signed with its SHA-256. The upload ends when the metadata is
/// applied (the engine does that after the last write) or the file is synchronized; the object
/// appears only then, whole, and its size is checked. A file closed before that is never stored
/// (an unfinished multipart upload is aborted).
actor S3WriteFile: WritableFile {
    static let partSize = 16 << 20
    /// S3 allows at most 10,000 parts.
    static let maxParts = 10_000

    nonisolated let path: VFSPath
    let bucket: String
    let key: String
    let provider: S3Provider

    private var buffer = Data()
    private var written: Int64 = 0
    /// The multipart upload's ID and the ETags of the parts sent.
    private var upload: String?
    private var parts: [String] = []
    /// Unix seconds for x-amz-meta-mtime.
    private var modified: Int?
    private var committed = false
    private var closed = false

    init(path: VFSPath, bucket: String, key: String, provider: S3Provider) {
        self.path = path
        self.bucket = bucket
        self.key = key
        self.provider = provider
    }

    private var action: String { "Uploading \(path.name)" }

    func write(_ data: Data, at offset: Int64) async throws {
        guard offset == written else { throw VFSError.unsupported("writing in the middle of a file on \(provider.host)") }
        guard !committed, !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        written += Int64(data.count)
        buffer.append(data)
        while buffer.count > Self.partSize { try await sendPart() }
    }

    /// Sends the next `partSize` bytes (or the rest, at the end) as a part.
    private func sendPart() async throws {
        if upload == nil {
            upload = try await provider.startMultipart(bucket, key, headers: ["Content-Type": S3Provider.contentType(for: path.name)],
                                                       action: action, path: path)
        }
        guard parts.count < Self.maxParts else {
            throw VFSError.failed("\(action) failed: S3 takes at most \(Self.maxParts) parts of \(Self.partSize >> 20) MB in one upload")
        }
        let part = Data(buffer.prefix(Self.partSize))
        let response = try await provider.send("PUT", bucket: bucket, key: key,
                                               query: [("partNumber", String(parts.count + 1)), ("uploadId", upload!)], body: part)
        guard response.isSuccess, let etag = response.header("ETag") else { throw provider.failure(response, action, path) }
        parts.append(etag)
        buffer.removeFirst(part.count)
    }

    func truncate(to length: Int64) async throws {
        guard length == written, !committed else {
            throw VFSError.unsupported("cutting a file short on \(provider.host)")
        }
    }

    /// Ends the upload and checks the size S3 stored.
    private func commit() async throws {
        guard !committed else { return }
        guard !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        if upload == nil {
            var headers = ["Content-Type": S3Provider.contentType(for: path.name)]
            if let modified { headers["x-amz-meta-mtime"] = String(modified) }
            let response = try await provider.send("PUT", bucket: bucket, key: key, headers: headers, body: buffer)
            guard response.isSuccess else { throw provider.failure(response, action, path) }
        } else {
            if !buffer.isEmpty { try await sendPart() }
            try await provider.completeMultipart(bucket, key, upload: upload!, parts: parts, action: action, path: path)
        }
        committed = true
        buffer = Data()
        provider.uncommitted.withLock { _ = $0.remove(path.path) }
        guard let stored = try await provider.head(bucket, key, path) else {
            throw VFSError.failed("\(action) failed: \(provider.host) did not keep it")
        }
        if let size = Int64(stored.header("Content-Length") ?? ""), size != written {
            throw VFSError.failed("\(action) failed: \(provider.host) stored \(size) of its \(written) bytes")
        }
        if upload != nil, let modified {
            // A multipart upload takes its metadata at the start, before the date was known.
            if path.name.hasPrefix(".basil-partial-") {
                // The copy engine's partial file: the rename into place (a copy) stores it.
                provider.pendingDates.withLock { $0[path.path] = modified }
            } else {
                _ = try await provider.applyMetadata(FileMetadata(modified: timespec(tv_sec: modified, tv_nsec: 0)), to: path)
            }
        }
    }

    func synchronize() async throws { try await commit() }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        if committed {
            // Committed early (read-back verification): a partial file gets its date from the
            // rename into place, which copies it anyway.
            if path.name.hasPrefix(".basil-partial-"), let time = metadata.modified {
                provider.pendingDates.withLock { $0[path.path] = time.tv_sec }
                return []
            }
            return try await provider.applyMetadata(metadata, to: path)
        }
        if let time = metadata.modified { modified = time.tv_sec }
        try await commit()
        return []
    }

    func close() async {
        guard !committed, !closed else { return }
        closed = true
        buffer = Data()
        if let upload { await provider.abortMultipart(bucket, key, upload: upload) }
    }
}
