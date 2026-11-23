import BasilCore
import BasilVFS
import CryptoKit
import Foundation

/// The copy engine's partial file on a WebDAV server, written from the start (no random
/// access). Up to `smallFile` bytes it stays in memory and goes up in one PUT. A larger file is
/// sent while it is written: on Nextcloud in chunks of `chunkSize` (its chunked upload, put
/// together by a MOVE that carries the date and a SHA-1 checksum), elsewhere as one streamed PUT,
/// or, on a server that wants every upload's length first (411), through a local temporary
/// file. The upload ends when the metadata is applied (the engine does that after the last
/// write) or the file is synchronized; then the server's listing must show the whole size. A
/// file closed before that is never stored.
actor WebDAVWriteFile: WritableFile {
    static let smallFile = 8 << 20
    static let chunkSize = 10 << 20

    nonisolated let path: VFSPath
    let provider: WebDAVProvider

    private enum Mode {
        case memory
        case stream(HTTPStreamUpload)
        case spool(FileHandle, URL)
        /// Nextcloud's upload folder (a server path) and the number of the next chunk.
        case chunks(String, Int)
    }

    private var mode = Mode.memory
    private var buffer = Data()
    private var written: Int64 = 0
    private var sha1 = Insecure.SHA1()
    /// Unix seconds for the stored date.
    private var modified: Int?
    private var committed = false
    private var closed = false

    init(path: VFSPath, provider: WebDAVProvider) {
        self.path = path
        self.provider = provider
    }

    private var action: String { "Uploading \(path.name)" }

    func write(_ data: Data, at offset: Int64) async throws {
        guard offset == written else { throw VFSError.unsupported("writing in the middle of a file on a WebDAV server") }
        guard !committed, !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        written += Int64(data.count)
        if provider.nextcloud != nil { sha1.update(data: data) }
        switch mode {
        case .memory:
            buffer.append(data)
            if buffer.count > Self.smallFile { try await growLarge() }
        case .chunks:
            buffer.append(data)
            while buffer.count >= Self.chunkSize { try await sendChunk() }
        case .stream(let upload):
            try await send(data, through: upload)
        case .spool(let handle, _):
            try await WebDAVIO.run { try handle.write(contentsOf: data) }
        }
    }

    /// The file outgrew memory: start sending it.
    private func growLarge() async throws {
        if let nextcloud = provider.nextcloud {
            let folder = nextcloud.uploads + "/basil-" + UUID().uuidString
            let response = try await provider.send("MKCOL", provider.url(server: folder, folder: true),
                                                   headers: ["Destination": provider.url(path).absoluteString], retry: false)
            guard response.isSuccess else { throw provider.failure(response, action, path) }
            mode = .chunks(folder, 1)
            while buffer.count >= Self.chunkSize { try await sendChunk() }
        } else if provider.needsLength.withLock({ $0 }) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Basil WebDAV uploads")
            let file = folder.appendingPathComponent(UUID().uuidString)
            let pending = buffer
            let handle = try await WebDAVIO.run { () throws -> FileHandle in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: file)
                try handle.write(contentsOf: pending)
                return handle
            }
            mode = .spool(handle, file)
            buffer = Data()
        } else {
            let upload = provider.client.streamedUpload("PUT", provider.url(path),
                                                        headers: ["Content-Type": "application/octet-stream"])
            mode = .stream(upload)
            let pending = buffer
            buffer = Data()
            try await send(pending, through: upload)
        }
    }

    private func send(_ data: Data, through upload: HTTPStreamUpload) async throws {
        do {
            try await upload.write(data)
        } catch is HTTPStreamUpload.Ended {
            // The server answered before the end: an error.
            let response = try await upload.answer()
            throw refused(response)
        }
    }

    /// Uploads the next chunk (up to `chunkSize` buffered bytes) to Nextcloud's upload folder.
    private func sendChunk() async throws {
        guard case .chunks(let folder, let number) = mode else { return }
        let part = Data(buffer.prefix(Self.chunkSize))
        let name = String(format: "%05d", number)
        let response = try await provider.send("PUT", provider.url(server: folder + "/" + name), headers: [
            "Destination": provider.url(path).absoluteString, "Content-Type": "application/octet-stream",
        ], body: part)
        guard response.isSuccess else { throw provider.failure(response, action, path) }
        buffer.removeFirst(part.count)
        mode = .chunks(folder, number + 1)
    }

    func truncate(to length: Int64) async throws {
        guard length == written, !committed else {
            throw VFSError.unsupported("cutting a file short on a WebDAV server")
        }
    }

    private func refused(_ response: HTTPResponse) -> Error {
        if response.status == 411 {
            provider.needsLength.withLock { $0 = true }
            return VFSError.failed("\(action) failed: \(provider.host) needs the size of a file before it is uploaded. Retry: large files now go through a temporary copy on this Mac first.")
        }
        return provider.failure(response, action, path)
    }

    /// Ends the upload and checks the size the server stored.
    private func commit() async throws {
        guard !committed else { return }
        guard !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        var headers: [String: String] = [:]
        if let modified { headers["X-OC-Mtime"] = String(modified) }
        if provider.nextcloud != nil {
            headers["OC-Checksum"] = "SHA1:" + sha1.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let target = provider.url(path)
        let response: HTTPResponse
        switch mode {
        case .memory:
            headers["Content-Type"] = "application/octet-stream"
            response = try await provider.send("PUT", target, headers: headers, body: buffer)
        case .stream(let upload):
            response = try await upload.finish()
        case .spool(let handle, let file):
            try await WebDAVIO.run { try handle.close() }
            headers["Content-Type"] = "application/octet-stream"
            defer { try? FileManager.default.removeItem(at: file) }
            response = try await provider.send("PUT", target, headers: headers, file: file)
        case .chunks(let folder, _):
            if !buffer.isEmpty { try await sendChunk() }
            headers["Destination"] = target.absoluteString
            headers["OC-Total-Length"] = String(written)
            response = try await provider.send("MOVE", provider.url(server: folder + "/.file"), headers: headers, retry: false)
        }
        guard response.isSuccess else { throw refused(response) }
        committed = true
        buffer = Data()
        provider.uncommitted.withLock { _ = $0.remove(path.path) }
        let stored = try await provider.entry(path)
        if let size = stored.size, size != written {
            throw VFSError.failed("\(action) failed: \(provider.host) stored \(size) of its \(written) bytes")
        }
    }

    func synchronize() async throws { try await commit() }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        if committed {
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
        switch mode {
        case .memory:
            break
        case .stream(let upload):
            upload.cancel()
        case .spool(let handle, let file):
            try? await WebDAVIO.run {
                try handle.close()
                try FileManager.default.removeItem(at: file)
            }
        case .chunks(let folder, _):
            _ = try? await provider.send("DELETE", provider.url(server: folder, folder: true), retry: false)
        }
    }
}

/// Blocking file I/O for uploads, off the cooperative pool.
enum WebDAVIO {
    private static let queue = DispatchQueue(label: "Basil WebDAV file I/O", attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
