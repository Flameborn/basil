import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization

extension ProviderID {
    /// WebDAV over plain HTTP.
    public static let webdav = ProviderID("webdav")
    /// WebDAV over HTTPS.
    public static let webdavs = ProviderID("webdavs")
}

/// What a Nextcloud server adds to WebDAV, found when connecting.
struct NextcloudServer: Sendable {
    /// Where Nextcloud is installed on the server ("" or "/nextcloud").
    var prefix: String
    /// The user's ID, which names the DAV folders (it can differ from the login name).
    var userID: String
    /// The trash bin app answers.
    var trash: Bool

    var dav: String { prefix + "/remote.php/dav" }
    var uploads: String { dav + "/uploads/" + userID }
    var trashBin: String { dav + "/trashbin/" + userID + "/trash" }
}

/// Files on a WebDAV server. Paths are relative to the connection's top folder on the server
/// (`root`: the highest folder of the given path that still answers WebDAV, or a Nextcloud
/// user's files). WebDAV has no random-access writes and no fsync: the copy engine writes each
/// partial file from the start (small files in one PUT, larger ones streamed, or on Nextcloud
/// uploaded in checked chunks), and a file is complete once the server confirmed it and listed
/// it with its full size. Reads are ranged GETs. Copies inside the server are server-side
/// (COPY), moves are MOVE. Replacing goes through MOVE with Overwrite, which servers do by
/// deleting the target first. Fingerprints carry the ETag, so any change the server notices
/// changes them. On Nextcloud dates are kept (X-OC-Mtime), F8 goes to its trash bin and a
/// permanent delete also empties the item from there. Folders are not watched.
public final class WebDAVProvider: WritableProvider, ConnectedProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let client: HTTPClient
    /// Decoded server path of "/", without a trailing slash ("" for the server's top).
    let root: String
    let nextcloud: NextcloudServer?
    /// Files created and not yet uploaded (their paths). Until the upload ends they do not
    /// exist on the server, so removing one only forgets it.
    let uncommitted = Mutex<Set<String>>([])
    /// The server refused an upload without a length (411): later large uploads are written to
    /// a local file first.
    let needsLength = Mutex(false)

    public var connectionTitle: String { client.endpoint.account }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/") }

    public var capabilities: ProviderCapabilities {
        var result: ProviderCapabilities = [.read, .write, .randomAccessRead, .rename, .clone]
        if nextcloud != nil { result.insert(.setDates) }
        if nextcloud?.trash == true { result.insert(.trash) }
        return result
    }

    init(client: HTTPClient, root: String, nextcloud: NextcloudServer?, identity: String) {
        self.client = client
        self.root = root
        self.nextcloud = nextcloud
        location = ProviderLocation(provider: client.endpoint.service, instance: identity)
    }

    public func disconnect() async { client.close() }

    var host: String { client.endpoint.hostAndPort }

    // MARK: Paths

    /// The URL of an item; folders get a trailing slash.
    func url(_ path: VFSPath, folder: Bool = false) -> URL {
        url(server: root + (path.isRoot ? "" : path.path), folder: folder || path.isRoot)
    }

    /// The URL of a decoded server path.
    func url(server path: String, folder: Bool = false) -> URL {
        URL(string: client.endpoint.origin + DAVPath.encode(path) + (folder ? "/" : ""))!
    }

    /// The path of an href below `root`, or nil when it is elsewhere.
    func path(ofHref href: String) -> VFSPath? {
        let server = DAVPath.decode(href)
        guard server == root || server.hasPrefix(root + "/") else { return nil }
        let rest = String(server.dropFirst(root.count))
        return VFSPath(location: location, path: rest.isEmpty ? "/" : rest)
    }

    /// A path relative to the user's files, as Nextcloud's trash names it ("a/b.txt").
    func relative(_ path: VFSPath) -> String { String(path.path.dropFirst()) }

    // MARK: Calls

    /// Sends a request and turns a lost login into words.
    func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
              file: URL? = nil, retry: Bool = true) async throws -> HTTPResponse {
        do {
            return try await client.send(method, url, headers: headers, body: body, file: file, retry: retry)
        } catch is HTTPUnauthorized {
            throw VFSError.failed("\(host) no longer accepts the login. Disconnect and connect again.")
        } catch is UntrustedCertificate {
            throw VFSError.failed("The TLS certificate of \(host) changed while connected. Connect again to check it.")
        }
    }

    /// A refused request in VFS terms.
    func failure(_ response: HTTPResponse, _ action: String, _ path: VFSPath) -> Error {
        switch response.status {
        case 404, 410: return VFSError.notFound(path)
        case 403: return VFSError.permissionDenied(path)
        case 423: return VFSError.failed("\(action) failed: \(path.name) is locked on the server")
        case 507: return VFSError.failed("\(action) failed: there is no space left on \(host)")
        case 413: return VFSError.failed("\(action) failed: \(host) does not take files this large")
        default: return VFSError.failed("\(action) failed: \(response.problem)")
        }
    }

    /// PROPFIND with Depth 0 or 1.
    func propfind(_ url: URL, depth: Int, extra: [(String, String)] = []) async throws -> HTTPResponse {
        try await send("PROPFIND", url, headers: ["Depth": String(depth), "Content-Type": "application/xml; charset=utf-8"],
                       body: DAVXML.propfind(nextcloud: nextcloud != nil, extra: extra))
    }

    /// The entry of one item, or nil when nothing is there.
    func lookUp(_ path: VFSPath) async throws -> DAVEntry? {
        let response = try await propfind(url(path), depth: 0)
        if response.status == 404 || response.status == 410 { return nil }
        guard response.status == 207 else { throw failure(response, "Reading \(path.displayName)", path) }
        let entries = try parse(response, path)
        return entries.first { self.path(ofHref: $0.href) == path } ?? entries.first
    }

    func entry(_ path: VFSPath) async throws -> DAVEntry {
        guard let entry = try await lookUp(path) else { throw VFSError.notFound(path) }
        return entry
    }

    func parse(_ response: HTTPResponse, _ path: VFSPath) throws -> [DAVEntry] {
        do { return try DAVXML.parse(response.body) } catch let error as DAVXML.DAVParseError {
            throw VFSError.failed("\(host) sent an unreadable listing of \(path.displayName): \(error.message)")
        }
    }

    func item(_ entry: DAVEntry, at path: VFSPath) -> FileItem {
        FileItem(path: path, kind: entry.isCollection ? .directory : .file,
                 size: entry.isCollection ? nil : (entry.size ?? 0), modified: entry.modified, created: entry.created,
                 isHidden: path.name.hasPrefix("."), fileID: (entry.fileID ?? entry.etag).map(Self.number))
    }

    /// A stable 64-bit number for an ID or ETag (FNV-1a).
    static func number(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await propfind(url(directory, folder: true), depth: 1)
                    guard response.status == 207 else {
                        throw failure(response, "Listing \(directory.displayName)", directory)
                    }
                    let entries = try parse(response, directory)
                    var batch: [FileItem] = []
                    for entry in entries {
                        guard let path = path(ofHref: entry.href) else { continue }
                        if path == directory {
                            if !entry.isCollection { throw VFSError.notADirectory(directory) }
                            continue
                        }
                        guard path.parent == directory else { continue }
                        batch.append(item(entry, at: path))
                        if batch.count == 500 {
                            continuation.yield(batch)
                            batch = []
                        }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: path, kind: .directory) }
        return item(try await entry(path), at: path)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let entry = try await entry(path)
        if entry.isCollection {
            return FileFingerprint(kind: .directory, size: 0, fileID: entry.fileID.map(Self.number))
        }
        // The ETag changes with every change the server sees.
        let nanos = entry.modified.map { Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded()) }
        let identity = [entry.fileID, entry.etag].compactMap { $0 }.joined(separator: " ")
        return FileFingerprint(kind: .file, size: entry.size ?? 0, modifiedNanos: nanos,
                               fileID: identity.isEmpty ? nil : Self.number(identity))
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let entry = try await entry(path)
        var metadata = FileMetadata()
        if let date = entry.modified {
            metadata.modified = timespec(tv_sec: Int(date.timeIntervalSince1970.rounded(.down)), tv_nsec: 0)
        }
        return metadata
    }

    /// Nextcloud keeps modification dates (d:lastmodified). Plain WebDAV servers keep their own
    /// (RFC 4918 makes getlastmodified read-only), and nothing else of the metadata; that is left
    /// out quietly, as on FTP servers.
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        guard nextcloud != nil, let modified = metadata.modified, !path.isRoot else { return [] }
        let folder = (try? await lookUp(path))?.isCollection ?? false
        let response = try await send("PROPPATCH", url(path, folder: folder),
                                      headers: ["Content-Type": "application/xml; charset=utf-8"],
                                      body: DAVXML.setModified(seconds: modified.tv_sec))
        return response.isSuccess ? [] : ["could not set the date (\(response.problem))"]
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        "webdav:" + client.endpoint.origin + root
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        let entry = try await entry(path)
        if entry.isCollection { throw VFSError.failed("\(path.displayName) is a folder") }
        let url = url(path)
        let client = client
        return HTTPReadFile(name: path.name, start: { client.download(url, from: $0) },
                            currentSize: { try? await self.lookUp(path)?.size },
                            failure: { self.failure($0, "Reading \(path.name)", path) })
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        if path.isRoot { throw VFSError.alreadyExists(path) }
        if try await lookUp(path) != nil { throw VFSError.alreadyExists(path) }
        uncommitted.withLock { _ = $0.insert(path.path) }
        return WebDAVWriteFile(path: path, provider: self)
    }

    /// MOVE inside the server. Without `replacing` an existing target is refused (Overwrite: F).
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        let entry = try await entry(from)
        let folder = entry.isCollection
        let caseOnly = from.path != to.path && from.path.lowercased() == to.path.lowercased()
        let action = "Renaming \(from.name)"
        var response = try await move(from, to, folder: folder, overwrite: replacing)
        if response.status == 412, caseOnly {
            // A server whose names do not differ by case alone: go through a temporary name.
            let temporary = to.parent!.appending(".basil-rename-\(UInt32.random(in: .min ... .max))-\(to.name)")
            response = try await move(from, temporary, folder: folder, overwrite: false)
            guard response.isSuccess else { throw failure(response, action, from) }
            response = try await move(temporary, to, folder: folder, overwrite: false)
        }
        if response.isSuccess { return }
        if response.status == 412 { throw VFSError.alreadyExists(to) }
        if response.status == 409 { throw VFSError.notFound(to.parent ?? to) }
        throw failure(response, action, from)
    }

    private func move(_ from: VFSPath, _ to: VFSPath, folder: Bool, overwrite: Bool) async throws -> HTTPResponse {
        try await send("MOVE", url(from, folder: folder), headers: [
            "Destination": url(to, folder: folder).absoluteString,
            "Overwrite": overwrite ? "T" : "F",
        ], retry: false)
    }

    /// A server-side copy (COPY): no data goes through this Mac.
    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        let response = try await send("COPY", url(from), headers: [
            "Destination": url(to).absoluteString, "Overwrite": "F", "Depth": "0",
        ], retry: false)
        if response.isSuccess { return }
        if response.status == 412 { throw VFSError.alreadyExists(to) }
        if response.status == 409 { throw VFSError.notFound(to.parent ?? to) }
        if response.status == 501 || response.status == 405 { throw VFSError.unsupported("copying on \(host)") }
        throw failure(response, "Copying \(from.name)", from)
    }

    /// Removes a file or an empty folder (DELETE would take a full folder with everything in
    /// it, so a folder is checked first). On Nextcloud the item goes to the trash bin first and
    /// is then removed from there too.
    public func remove(_ path: VFSPath) async throws {
        guard !path.isRoot else { throw VFSError.permissionDenied(path) }
        // A partial file the copy engine writes again from the start was never uploaded.
        if uncommitted.withLock({ $0.remove(path.path) }) != nil, try await lookUp(path) == nil { return }
        let entry = try await entry(path)
        if entry.isCollection {
            let response = try await propfind(url(path, folder: true), depth: 1)
            if response.status == 207 {
                let children = try parse(response, path).compactMap { self.path(ofHref: $0.href) }.filter { $0 != path }
                if !children.isEmpty { throw VFSError.directoryNotEmpty(path) }
            }
        }
        try await delete(path, folder: entry.isCollection)
        if nextcloud?.trash == true { try await purgeFromTrash(path) }
    }

    private func delete(_ path: VFSPath, folder: Bool) async throws {
        let response = try await send("DELETE", url(path, folder: folder), retry: false)
        guard response.isSuccess else { throw failure(response, "Deleting \(path.name)", path) }
    }

    /// Nextcloud's trash bin: the item (a folder with everything in it) can be restored in its
    /// web page.
    public func trash(_ path: VFSPath) async throws {
        guard nextcloud?.trash == true else { throw VFSError.unsupported("moving to the trash on \(host)") }
        guard !path.isRoot else { throw VFSError.permissionDenied(path) }
        let entry = try await entry(path)
        try await delete(path, folder: entry.isCollection)
    }

    /// Removes the newest trash bin entry that came from `path` (just deleted). Nothing there
    /// (files the trash bin does not keep) is fine.
    func purgeFromTrash(_ path: VFSPath) async throws {
        guard let nextcloud else { return }
        let ns = DAVNamespace.nextcloud
        let response = try await send("PROPFIND", url(server: nextcloud.trashBin, folder: true), headers: [
            "Depth": "1", "Content-Type": "application/xml; charset=utf-8",
        ], body: DAVXML.propfind(nextcloud: false, extra: [
            ("nc", "trashbin-filename"), ("nc", "trashbin-original-location"), ("nc", "trashbin-deletion-time"),
        ]))
        guard response.status == 207 else { return }
        let wanted = relative(path)
        let entries = (try? DAVXML.parse(response.body)) ?? []
        let match = entries
            .filter { $0.value(ns, "trashbin-original-location") == wanted }
            .max { (Int($0.value(ns, "trashbin-deletion-time") ?? "") ?? 0) < (Int($1.value(ns, "trashbin-deletion-time") ?? "") ?? 0) }
        guard let match else { return }
        let server = DAVPath.decode(match.href)
        let gone = try await send("DELETE", url(server: server, folder: match.isCollection), retry: false)
        guard gone.isSuccess || gone.status == 404 else {
            throw VFSError.failed("\(path.name) was moved to the trash bin of \(host), but removing it from there failed: \(gone.problem)")
        }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        guard !path.isRoot else { throw VFSError.alreadyExists(path) }
        let response = try await send("MKCOL", url(path, folder: true), retry: false)
        if response.isSuccess { return }
        switch response.status {
        case 405: throw VFSError.alreadyExists(path)
        case 409: throw VFSError.notFound(path.parent ?? path)
        default: throw failure(response, "Making \(path.name)", path)
        }
    }

    /// WebDAV cannot flush a file; the server stored it when it confirmed the upload.
    public func synchronize(_ path: VFSPath) async throws {}

    public func readSymlink(_ path: VFSPath) async throws -> String {
        throw VFSError.unsupported("links on a WebDAV server")
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links on a WebDAV server")
    }
}
