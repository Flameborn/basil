import BasilCore
import BasilVFS
import Foundation

/// The copy engine's partial file on OneDrive, written from the start (OneDrive has no
/// random-access writes). Up to `smallFile` bytes it stays in memory and goes up in one PUT.
/// A larger file is kept in a temporary file ("Basil OneDrive uploads") until the end, because
/// every piece of an upload session must state the file's total size; it then goes up through
/// an upload session in `chunkSize` pieces, created with the file's date. The upload happens
/// when the metadata is applied (the engine does that after the last write) or the file is
/// synchronized; only then does the file exist in OneDrive, and its size and QuickXorHash must
/// match what was written. A file closed before that is never stored.
actor OneDriveWriteFile: WritableFile {
    static let smallFile = 4 << 20
    /// A multiple of 320 KiB, as OneDrive wants for every piece but the last.
    static let chunkSize = 32 * 320 * 1024

    nonisolated let path: VFSPath
    let parent: OneDriveRef
    let provider: OneDriveProvider

    private var buffer = Data()
    private var spool: (handle: FileHandle, file: URL)?
    private var written: Int64 = 0
    private var hash = QuickXorHash()
    /// The date for fileSystemInfo, RFC 3339.
    private var modified: String?
    private var session: URL?
    private var committed = false
    private var closed = false

    init(path: VFSPath, parent: OneDriveRef, provider: OneDriveProvider) {
        self.path = path
        self.parent = parent
        self.provider = provider
    }

    private var action: String { "Uploading \(path.name)" }

    func write(_ data: Data, at offset: Int64) async throws {
        guard offset == written else { throw VFSError.unsupported("writing in the middle of a file on OneDrive") }
        guard !committed, !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        written += Int64(data.count)
        hash.update(data)
        if let spool {
            let handle = spool.handle
            try await WebDAVIO.run { try handle.write(contentsOf: data) }
        } else if buffer.count + data.count <= Self.smallFile {
            buffer.append(data)
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Basil OneDrive uploads")
            let file = folder.appendingPathComponent(UUID().uuidString)
            let pending = buffer + data
            let handle = try await WebDAVIO.run { () throws -> FileHandle in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: file)
                try handle.write(contentsOf: pending)
                return handle
            }
            spool = (handle, file)
            buffer = Data()
        }
    }

    func truncate(to length: Int64) async throws {
        guard length == written, !committed else { throw VFSError.unsupported("cutting a file short on OneDrive") }
    }

    /// Uploads the file and checks what OneDrive stored.
    private func commit() async throws {
        guard !committed else { return }
        guard !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        let stored: GraphItem
        if let spool {
            stored = try await uploadSession(spool.handle, spool.file)
        } else {
            let address = provider.url(provider.childPath(parent, path.name) + "/content",
                                       [("@microsoft.graph.conflictBehavior", "fail")])
            let response = try await provider.send("PUT", address, body: buffer,
                                                   headers: ["Content-Type": "application/octet-stream"], retry: false)
            stored = try provider.decode(GraphItem.self, response, action, path)
        }
        committed = true
        buffer = Data()
        provider.uncommitted.withLock { _ = $0.remove(path.path) }
        var item = stored
        if let size = item.size, size != written {
            throw VFSError.failed("\(action) failed: OneDrive stored \(size) of its \(written) bytes")
        }
        if let theirs = item.file?.hashes?.quickXorHash, theirs != hash.base64 {
            throw VFSError.failed("\(action) failed: the file OneDrive stored differs from the one sent (QuickXorHash)")
        }
        if spool == nil, let modified {
            let patched = try await provider.send("PATCH", provider.url(provider.itemPath(parent.contentDrive, item.id), [("$select", GraphItem.select)]),
                                                  json: ["fileSystemInfo": ["lastModifiedDateTime": modified]])
            if patched.isSuccess, let file = try? JSONDecoder().decode(GraphItem.self, from: patched.body) { item = file }
        }
        spool = nil
        provider.remember(path, OneDriveRef.of(item, drive: parent.contentDrive))
    }

    /// Sends the spooled file through an upload session, piece by piece with the total size.
    private func uploadSession(_ handle: FileHandle, _ file: URL) async throws -> GraphItem {
        try await WebDAVIO.run { try handle.close() }
        defer { try? FileManager.default.removeItem(at: file) }
        var item: [String: Any] = ["@microsoft.graph.conflictBehavior": "fail"]
        if let modified { item["fileSystemInfo"] = ["lastModifiedDateTime": modified] }
        let created = try await provider.send("POST", provider.url(provider.childPath(parent, path.name) + "/createUploadSession"),
                                              json: ["item": item], retry: false)
        struct Session: Decodable { var uploadUrl: String }
        let answer = try provider.decode(Session.self, created, action, path)
        guard let url = URL(string: answer.uploadUrl) else {
            throw VFSError.failed("\(action) failed: OneDrive sent an upload address Basil cannot read")
        }
        session = url
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var sent: Int64 = 0
        repeat {
            try Task.checkCancellation()
            let part = try await WebDAVIO.run { try reader.read(upToCount: Self.chunkSize) ?? Data() }
            let last = sent + Int64(part.count) - 1
            // The upload address carries its own authorisation: no token is sent to it.
            let response = try await provider.client.send("PUT", url, headers: [
                "Content-Range": "bytes \(sent)-\(last)/\(written)", "Content-Type": "application/octet-stream",
            ], body: part, retry: false)
            sent = last + 1
            if sent >= written {
                guard response.status == 200 || response.status == 201 else { throw failed(response) }
                session = nil
                return try provider.decode(GraphItem.self, response, action, path)
            }
            guard response.status == 202 else { throw failed(response) }
            struct Progress: Decodable { var nextExpectedRanges: [String]? }
            let next = (try? JSONDecoder().decode(Progress.self, from: response.body))?.nextExpectedRanges?.first
            guard next.map({ $0.hasPrefix("\(sent)-") || $0 == String(sent) }) ?? true else {
                throw VFSError.failed("\(action) failed: OneDrive kept a different part of the upload than was sent")
            }
        } while sent < written
        throw VFSError.failed("\(action) failed: the upload ended early")
    }

    private func failed(_ response: HTTPResponse) -> Error {
        provider.failure(response, action, path)
    }

    func synchronize() async throws {
        do { try await commit() } catch {
            await cancelSession()
            throw error
        }
    }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        if committed { return try await provider.applyMetadata(metadata, to: path) }
        if let time = metadata.modified { modified = DriveDate.format(seconds: time.tv_sec, nanos: time.tv_nsec) }
        do { try await commit() } catch {
            await cancelSession()
            throw error
        }
        return []
    }

    private func cancelSession() async {
        guard let session else { return }
        self.session = nil
        _ = try? await provider.client.send("DELETE", session, retry: false)
    }

    func close() async {
        guard !committed, !closed else { return }
        closed = true
        buffer = Data()
        await cancelSession()
        if let spool {
            self.spool = nil
            try? await WebDAVIO.run {
                try? spool.handle.close()
                try FileManager.default.removeItem(at: spool.file)
            }
        }
    }
}
