import BasilCore
import BasilVFS
import CryptoKit
import Foundation

/// The copy engine's partial file on Google Drive, written from the start (Drive has no
/// random-access writes). Up to `smallFile` bytes it stays in memory and goes up in one
/// multipart request with its name, folder and date; a larger file becomes a resumable upload
/// sent in `chunkSize` pieces. The upload ends when the metadata is applied (the engine does
/// that after the last write) or the file is synchronized; only then does the file exist in
/// Drive, and its size and MD5 must match what was written. A file closed before that is never
/// stored (the resumable upload is cancelled).
actor GoogleDriveWriteFile: WritableFile {
    static let smallFile = 5 << 20
    /// A multiple of 256 KB, as Drive wants for every piece but the last.
    static let chunkSize = 8 << 20

    nonisolated let path: VFSPath
    let parent: DriveRef
    let provider: GoogleDriveProvider

    private var buffer = Data()
    private var written: Int64 = 0
    /// Bytes Drive confirmed of a resumable upload.
    private var sent: Int64 = 0
    private var session: URL?
    private var md5 = Insecure.MD5()
    /// RFC 3339 date for modifiedTime.
    private var modified: String?
    private var committed = false
    private var closed = false

    init(path: VFSPath, parent: DriveRef, provider: GoogleDriveProvider) {
        self.path = path
        self.parent = parent
        self.provider = provider
    }

    private var action: String { "Uploading \(path.name)" }

    func write(_ data: Data, at offset: Int64) async throws {
        guard offset == written else { throw VFSError.unsupported("writing in the middle of a file on Google Drive") }
        guard !committed, !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        written += Int64(data.count)
        md5.update(data: data)
        buffer.append(data)
        if session == nil, buffer.count > Self.smallFile { try await startSession() }
        // The last piece is sent at the end, with the total size.
        while session != nil, buffer.count > Self.chunkSize { try await sendChunk() }
    }

    /// The new file's name, folder and date as JSON.
    private func metadata() throws -> Data {
        var json: [String: Any] = ["name": path.name, "parents": [parent.contentID ?? ""]]
        if let modified { json["modifiedTime"] = modified }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private static let json = "application/json; charset=UTF-8"

    private func startSession() async throws {
        let response = try await provider.send("POST", provider.url("/files", [("uploadType", "resumable"), ("supportsAllDrives", "true")], upload: true),
                                               body: try metadata(), headers: ["Content-Type": Self.json, "X-Upload-Content-Type": "application/octet-stream"])
        guard response.isSuccess, let location = response.header("Location"), let url = URL(string: location) else {
            throw provider.failure(response, action, path)
        }
        session = url
    }

    /// Sends the next `chunkSize` bytes of a resumable upload. Drive answers 308 with the range
    /// it has.
    private func sendChunk() async throws {
        guard let session else { return }
        let part = Data(buffer.prefix(Self.chunkSize))
        let last = sent + Int64(part.count) - 1
        let response = try await provider.send("PUT", session, body: part,
                                               headers: ["Content-Range": "bytes \(sent)-\(last)/*"], retry: false)
        guard response.status == 308 else { throw provider.failure(response, action, path) }
        guard response.header("Range") == "bytes=0-\(last)" else {
            throw VFSError.failed("\(action) failed: Google Drive kept a different part of the upload than was sent")
        }
        sent = last + 1
        buffer.removeFirst(part.count)
    }

    func truncate(to length: Int64) async throws {
        guard length == written, !committed else { throw VFSError.unsupported("cutting a file short on Google Drive") }
    }

    /// Ends the upload and checks what Drive stored.
    private func commit() async throws {
        guard !committed else { return }
        guard !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        let response: HTTPResponse
        if let session {
            let range = buffer.isEmpty ? "bytes */\(written)" : "bytes \(sent)-\(written - 1)/\(written)"
            response = try await provider.send("PUT", session, body: buffer, headers: ["Content-Range": range], retry: false)
        } else {
            let boundary = "basil-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body.append(try metadata())
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(buffer)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            response = try await provider.send("POST", provider.url("/files", [("uploadType", "multipart"), ("supportsAllDrives", "true"), ("fields", "id")], upload: true),
                                               body: body, headers: ["Content-Type": "multipart/related; boundary=\(boundary)"], retry: false)
        }
        struct Created: Decodable { var id: String }
        let created = try provider.decode(Created.self, response, action, path)
        committed = true
        buffer = Data()
        provider.uncommitted.withLock { _ = $0.remove(path.path) }
        var stored = try await provider.get(created.id, path)
        if let size = stored.byteCount, size != written {
            throw VFSError.failed("\(action) failed: Google Drive stored \(size) of its \(written) bytes")
        }
        let digest = md5.finalize().map { String(format: "%02x", $0) }.joined()
        if let checksum = stored.md5Checksum, checksum.lowercased() != digest {
            throw VFSError.failed("\(action) failed: the file Google Drive stored differs from the one sent (MD5)")
        }
        if session != nil, let modified, stored.modifiedTime.flatMap(DriveDate.parse) != DriveDate.parse(modified) {
            // A resumable upload took its metadata at the start, before the date was known.
            let patched = try await provider.send("PATCH", provider.url("/files/\(created.id)", [("supportsAllDrives", "true"), ("fields", DriveFile.fields)]),
                                                  body: Data(#"{"modifiedTime":"\#(modified)"}"#.utf8), headers: ["Content-Type": Self.json])
            if patched.isSuccess, let file = try? JSONDecoder().decode(DriveFile.self, from: patched.body) { stored = file }
        }
        provider.remember(path, GoogleDriveProvider.describe(stored, target: nil, volume: parent.volume).1)
    }

    func synchronize() async throws { try await commit() }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        if committed { return try await provider.applyMetadata(metadata, to: path) }
        if let time = metadata.modified { modified = DriveDate.format(seconds: time.tv_sec, nanos: time.tv_nsec) }
        try await commit()
        return []
    }

    func close() async {
        guard !committed, !closed else { return }
        closed = true
        buffer = Data()
        // Cancels the resumable upload (Drive answers 499).
        if let session { _ = try? await provider.send("DELETE", session, retry: false) }
    }
}
