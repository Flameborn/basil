import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization
@preconcurrency import SwiftyDropbox

extension ProviderID {
    public static let dropbox = ProviderID("dropbox")
}

/// One Dropbox account's files, through the SwiftyDropbox SDK's API routes. Paths are Dropbox
/// paths ("/" is the root, which the API calls ""). Dropbox has no random-access writes and no
/// atomic replacing rename: the copy engine uploads each partial file from the start through an
/// upload session (each part checked with Dropbox's content hash) and commits it when it is
/// synchronized; replacing removes the old file first (it stays restorable on dropbox.com).
/// Reads are ranged downloads of the revision current when the file was opened, so one read
/// pass sees one version of the file. A file's revision changes with every change, so the copy
/// engine sees any change to a source, also one of the same size within the same second.
/// Copies inside the account are server-side (`clone`), moves are renames. Folders are not
/// watched.
public final class DropboxProvider: WritableProvider, ConnectedProvider, SharedLinkProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let client: DropboxClient
    let tokens: DropboxTokens
    let auth: DropboxAuth
    /// "erion@example.com"
    public let email: String
    public let displayName: String
    public let signedInTarget: RemoteTarget?
    /// Files created and not yet committed (lower-cased paths). They do not exist in Dropbox
    /// until the upload is committed, so removing one only forgets it.
    let uncommitted = Mutex<Set<String>>([])

    public var connectionTitle: String { "Dropbox (\(email))" }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/") }
    public var capabilities: ProviderCapabilities {
        [.read, .write, .randomAccessRead, .rename, .setDates, .clone, .trash]
    }

    /// The team space's namespace ID when paths start there (`DropboxConnector.teamSpaceRoot`);
    /// Basil's own requests send it like the SDK's.
    let teamSpace: String?

    init(client: DropboxClient, tokens: DropboxTokens, auth: DropboxAuth, email: String, displayName: String,
         teamSpace: String? = nil, signedInTarget: RemoteTarget?) {
        self.client = client
        self.teamSpace = teamSpace
        self.tokens = tokens
        self.auth = auth
        self.email = email
        self.displayName = displayName
        self.signedInTarget = signedInTarget
        // The email address reads well in the path bar and in messages ("dropbox://erion@example.com/Photos").
        location = ProviderLocation(provider: .dropbox, instance: email)
    }

    public func disconnect() async {
        client.shutdown()
    }

    /// The API's name for a path: "" for the root.
    static func api(_ path: VFSPath) -> String { path.isRoot ? "" : path.path }

    // MARK: Calls

    /// Runs one SDK request, again after rate limits, server errors, network errors and an
    /// expired token (up to four tries), and turns its error into a `VFSError`.
    func call<R: HasRequestResponse>(_ action: String, _ path: VFSPath, to: VFSPath? = nil,
                                     _ make: () -> R) async throws -> R.ValueType {
        var attempt = 0
        while true {
            attempt += 1
            switch await make().responseResult() {
            case .success(let value):
                return value
            case .failure(let error):
                let problem = DropboxFailure(error)
                if attempt < 4, let wait = problem.retryAfter(attempt: attempt) {
                    if problem.expiredToken { tokens.expire() }
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                throw problem.vfsError(action, path, to: to, email: email)
            }
        }
    }

    func metadata(_ path: VFSPath) async throws -> Files.Metadata? {
        if path.isRoot { return nil }
        return try await call("Reading \(path.name)", path) {
            client.files.getMetadata(path: Self.api(path))
        }
    }

    /// The item at a path; the root is a folder without metadata.
    enum Entry {
        case root
        case file(Files.FileMetadata)
        case folder(Files.FolderMetadata)
    }

    func entry(_ path: VFSPath) async throws -> Entry {
        guard let metadata = try await metadata(path) else { return .root }
        if let file = metadata as? Files.FileMetadata { return .file(file) }
        if let folder = metadata as? Files.FolderMetadata { return .folder(folder) }
        throw VFSError.notFound(path)
    }

    /// nil when nothing is at the path.
    func lookUp(_ path: VFSPath) async throws -> Entry? {
        do { return try await entry(path) } catch VFSError.notFound { return nil }
    }

    func item(_ metadata: Files.Metadata, in directory: VFSPath) -> FileItem? {
        let path = directory.appending(metadata.name)
        let hidden = metadata.name.hasPrefix(".")
        if let file = metadata as? Files.FileMetadata {
            return FileItem(path: path, kind: .file, size: Int64(clamping: file.size), modified: file.clientModified,
                            isHidden: hidden, fileID: Self.number(file.id))
        }
        if let folder = metadata as? Files.FolderMetadata {
            return FileItem(path: path, kind: .directory, isHidden: hidden, fileID: Self.number(folder.id))
        }
        return nil
    }

    /// A stable 64-bit number for an id or revision string (FNV-1a).
    static func number(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func nanos(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    // MARK: Shared links

    /// The account's shared link for a file or folder (dropbox.com/scl/...), made with the
    /// account's default settings when there is none yet. Dropbox answers
    /// "shared_link_already_exists" for an existing one, with its metadata or without.
    public func sharedLink(for path: VFSPath, lifetime: LinkLifetime?) async throws -> URL {
        let action = "Copying the link of \(path.isRoot ? "Dropbox" : path.name)"
        let api = Self.api(path)
        switch await client.sharing.createSharedLinkWithSettings(path: api).responseResult() {
        case .success(let link):
            return try Self.url(link.url, action)
        case .failure(let error):
            if case .routeError(let box, _, _, _) = error,
               case .sharedLinkAlreadyExists(let existing) = box.unboxed {
                if case .metadata(let link)? = existing { return try Self.url(link.url, action) }
                let found = try await call(action, path) { client.sharing.listSharedLinks(path: api, directOnly: true) }
                guard let link = found.links.first else { throw VFSError.failed("\(action) failed: Dropbox lists no link") }
                return try Self.url(link.url, action)
            }
            let problem = DropboxFailure(error)
            if case .route(let summary, _) = problem.kind, summary.hasPrefix("email_not_verified") {
                throw VFSError.failed("\(action) failed: Dropbox makes links only for accounts with a verified email address")
            }
            if case .route(let summary, _) = problem.kind, summary.hasPrefix("access_denied") {
                throw VFSError.failed("\(action) failed: Dropbox does not allow a link to \(path.name)")
            }
            // Rate limits and the rest: once more through the usual retries and messages.
            let link = try await call(action, path) { client.sharing.createSharedLinkWithSettings(path: api) }
            return try Self.url(link.url, action)
        }
    }

    private static func url(_ text: String, _ action: String) throws -> URL {
        guard let url = URL(string: text) else { throw VFSError.failed("\(action) failed: Dropbox sent no usable link") }
        return url
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let action = "Listing \(directory.isRoot ? "Dropbox" : directory.name)"
                    var page = try await call(action, directory) {
                        client.files.listFolder(path: Self.api(directory), limit: 2000)
                    }
                    while true {
                        let batch = page.entries.compactMap { item($0, in: directory) }
                        if !batch.isEmpty { continuation.yield(batch) }
                        guard page.hasMore else { break }
                        try Task.checkCancellation()
                        let cursor = page.cursor
                        page = try await call(action, directory) { client.files.listFolderContinue(cursor: cursor) }
                    }
                    continuation.finish()
                } catch VFSError.notFound(let path) where path == directory {
                    // Listing a file says "not found" too.
                    if case .file? = try? await lookUp(directory) {
                        continuation.finish(throwing: VFSError.notADirectory(directory))
                    } else {
                        continuation.finish(throwing: VFSError.notFound(directory))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        guard let parent = path.parent, let metadata = try await metadata(path) else {
            return FileItem(path: path, kind: .directory)
        }
        guard let item = item(metadata, in: parent) else { throw VFSError.notFound(path) }
        return item
    }

    /// Keeps a pane live: the folder's latest cursor, then long-polls (Dropbox's notify host,
    /// no token) that end when something in the folder changed; each change reloads the pane and
    /// moves the cursor on with list_folder/continue, so nothing between two polls is missed.
    /// Errors wait 30 s and start over with a new cursor; Dropbox's backoff is honoured.
    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? {
        AsyncStream { continuation in
            let task = Task {
                var cursor: String?
                while !Task.isCancelled {
                    do {
                        if cursor == nil {
                            cursor = try await call("Watching \(directory.name)", directory) {
                                client.files.listFolderGetLatestCursor(path: Self.api(directory))
                            }.cursor
                        }
                        let (changes, backoff) = try await longpoll(cursor!)
                        if changes {
                            // Drain to the newest cursor before reloading.
                            var page = try await call("Watching \(directory.name)", directory) {
                                client.files.listFolderContinue(cursor: cursor!)
                            }
                            while page.hasMore {
                                let next = page.cursor
                                page = try await call("Watching \(directory.name)", directory) { client.files.listFolderContinue(cursor: next) }
                            }
                            cursor = page.cursor
                            continuation.yield(.reloadAll)
                        }
                        if let backoff { try await Task.sleep(for: .seconds(backoff)) }
                    } catch {
                        if Task.isCancelled { break }
                        cursor = nil
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One long-poll: whether the folder changed, and how many seconds Dropbox asks to wait.
    func longpoll(_ cursor: String) async throws -> (changes: Bool, backoff: Int?) {
        var request = URLRequest(url: URL(string: auth.hosts.notify + "/2/files/list_folder/longpoll")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(auth.hosts.longpollTimeout + 90)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor, "timeout": auth.hosts.longpollTimeout])
        let (data, response) = try await auth.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VFSError.failed("Dropbox did not answer the change check")
        }
        return (json["changes"] as? Bool ?? false, json["backoff"] as? Int)
    }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        switch try await entry(path) {
        case .root:
            return FileFingerprint(kind: .directory, size: 0)
        case .folder(let folder):
            return FileFingerprint(kind: .directory, size: 0, fileID: Self.number(folder.id))
        case .file(let file):
            // The revision changes with every change to the file.
            return FileFingerprint(kind: .file, size: Int64(clamping: file.size),
                                   modifiedNanos: Self.nanos(file.serverModified), fileID: Self.number(file.rev))
        }
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        guard case .file(let file) = try await entry(path) else { return FileMetadata() }
        let seconds = file.clientModified.timeIntervalSince1970.rounded(.down)
        return FileMetadata(modified: timespec(tv_sec: Int(seconds), tv_nsec: 0))
    }

    /// Dropbox keeps a file's date only from its upload, and nothing else of the metadata
    /// (permissions, extended attributes, flags). Folders have no dates. Left out quietly, as
    /// on FTP servers.
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] { [] }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        "dropbox:\(tokens.accountID)"
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        switch try await entry(path) {
        case .file(let file):
            return DropboxReadFile(path: path, revision: file.rev, size: Int64(clamping: file.size), provider: self)
        case .root, .folder:
            throw VFSError.failed("\(path.isRoot ? "Dropbox" : path.name) is a folder")
        }
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        if path.isRoot { throw VFSError.alreadyExists(path) }
        if try await lookUp(path) != nil { throw VFSError.alreadyExists(path) }
        uncommitted.withLock { _ = $0.insert(path.path.lowercased()) }
        return DropboxWriteFile(path: path, provider: self)
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        let action = "Renaming \(from.name)"
        let caseOnly = from.path != to.path && from.path.lowercased() == to.path.lowercased()
        do {
            _ = try await call(action, from, to: to) {
                client.files.moveV2(fromPath: Self.api(from), toPath: Self.api(to))
            }
        } catch VFSError.alreadyExists where caseOnly {
            // Dropbox names do not differ by case alone: go through a temporary name.
            let temporary = to.parent!.appending(".basil-rename-\(UInt32.random(in: .min ... .max))-\(to.name)")
            _ = try await call(action, from, to: temporary) {
                client.files.moveV2(fromPath: Self.api(from), toPath: Self.api(temporary))
            }
            _ = try await call(action, temporary, to: to) {
                client.files.moveV2(fromPath: Self.api(temporary), toPath: Self.api(to))
            }
        } catch VFSError.alreadyExists where replacing {
            // Dropbox cannot move onto a file. Removing it first is not atomic: for a moment
            // neither file has the name. The old file can be restored on dropbox.com.
            guard case .file(let existing)? = try await lookUp(to) else { throw VFSError.alreadyExists(to) }
            _ = try await call("Replacing \(to.name)", to) {
                client.files.deleteV2(path: Self.api(to), parentRev: existing.rev)
            }
            _ = try await call(action, from, to: to) {
                client.files.moveV2(fromPath: Self.api(from), toPath: Self.api(to))
            }
        }
    }

    /// A server-side copy (copy_v2): no data goes through this Mac.
    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        _ = try await call("Copying \(from.name)", from, to: to) {
            client.files.copyV2(fromPath: Self.api(from), toPath: Self.api(to))
        }
    }

    /// Removes a file or an empty folder. Dropbox would delete a full folder with everything in
    /// it, so a folder is checked first.
    public func remove(_ path: VFSPath) async throws {
        // A partial file the copy engine writes again from the start was never committed.
        if uncommitted.withLock({ $0.remove(path.path.lowercased()) }) != nil, try await lookUp(path) == nil { return }
        switch try await entry(path) {
        case .root:
            throw VFSError.permissionDenied(path)
        case .folder:
            let page = try await call("Deleting \(path.name)", path) {
                client.files.listFolder(path: Self.api(path), limit: 1)
            }
            guard page.entries.isEmpty, !page.hasMore else { throw VFSError.directoryNotEmpty(path) }
            _ = try await call("Deleting \(path.name)", path) { client.files.deleteV2(path: Self.api(path)) }
        case .file(let file):
            // Only the revision that was looked at.
            _ = try await call("Deleting \(path.name)", path) {
                client.files.deleteV2(path: Self.api(path), parentRev: file.rev)
            }
        }
    }

    /// Dropbox's delete: the item (a folder with everything in it) can be restored on
    /// dropbox.com for as long as the account keeps deleted files.
    public func trash(_ path: VFSPath) async throws {
        guard !path.isRoot else { throw VFSError.permissionDenied(path) }
        _ = try await call("Deleting \(path.name)", path) { client.files.deleteV2(path: Self.api(path)) }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        guard !path.isRoot else { throw VFSError.alreadyExists(path) }
        _ = try await call("Making \(path.name)", path) { client.files.createFolderV2(path: Self.api(path)) }
    }

    /// A file is stored once its upload is committed.
    public func synchronize(_ path: VFSPath) async throws {}

    public func readSymlink(_ path: VFSPath) async throws -> String {
        throw VFSError.unsupported("links in Dropbox")
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links in Dropbox")
    }

    // MARK: Downloads

    /// Bytes `range` of one revision, by a ranged download (Basil's own request: the SDK has no
    /// ranges). Retried like `call`.
    func download(_ path: VFSPath, revision: String, range: Range<Int64>) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: URL(string: auth.hosts.content + "/2/files/download")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(try await tokens.current())", forHTTPHeaderField: "Authorization")
            request.setValue(Self.headerJSON(["path": "rev:\(revision)"]), forHTTPHeaderField: "Dropbox-API-Arg")
            if let teamSpace {
                request.setValue(Self.headerJSON([".tag": "root", "root": teamSpace]), forHTTPHeaderField: "Dropbox-API-Path-Root")
            }
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await auth.session.data(for: request)
            } catch {
                if attempt < 4, !(error is CancellationError) {
                    try await Task.sleep(for: .seconds(1 << (attempt - 1)))
                    continue
                }
                throw VFSError.failed("Reading \(path.name) failed: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206:
                return data
            case 200:
                // The whole file (a server that ignored the range).
                let lower = Int(min(range.lowerBound, Int64(data.count)))
                let upper = Int(min(range.upperBound, Int64(data.count)))
                return data.subdata(in: lower..<upper)
            case 416:
                return Data()
            case 401 where attempt < 4:
                tokens.expire()
                continue
            case 429, 500...599 where attempt < 4:
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                try await Task.sleep(for: .seconds(header.flatMap(Double.init) ?? Double(1 << (attempt - 1))))
                continue
            case 409:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let summary = json?["error_summary"] as? String ?? ""
                if summary.contains("not_found") { throw VFSError.notFound(path) }
                throw VFSError.failed("Reading \(path.name) failed: \(summary)")
            default:
                throw VFSError.failed("Reading \(path.name) failed: HTTP \(status)")
            }
        }
    }

    /// JSON for a Dropbox-API-Arg header: everything outside ASCII escaped (\uXXXX), as HTTP
    /// headers are ASCII.
    static func headerJSON(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var text = ""
        for unit in String(decoding: data, as: UTF8.self).utf16 {
            if unit < 0x80 {
                text.unicodeScalars.append(Unicode.Scalar(unit)!)
            } else {
                text += String(format: "\\u%04x", unit)
            }
        }
        return text
    }
}

/// Dropbox's content hash (https://www.dropbox.com/developers/reference/content-hash): the
/// SHA-256 of the SHA-256 of each 4 MiB block. Sent with each part of an upload, so Dropbox
/// refuses a part that arrived damaged.
enum DropboxContentHash {
    static let blockSize = 4 << 20

    static func of(_ data: Data) -> String {
        var outer = SHA256()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + blockSize, data.endIndex)
            outer.update(data: Data(SHA256.hash(data: data[offset..<end])))
            offset = end
        }
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// An SDK error, sorted into what Basil does with it.
struct DropboxFailure {
    enum Kind {
        /// A route error with its summary ("path/not_found/..", "to/conflict/file/..").
        case route(String, String?)
        case expiredToken
        case signInRefused(String)
        /// The sign-in lacks a permission (scope) the call needs.
        case missingScope(String)
        case rateLimited(UInt64)
        case serverError(String)
        case network(String)
        case other(String)
    }

    let kind: Kind

    init<E>(_ error: CallError<E>) {
        switch error {
        case .routeError(_, let message, let summary, _):
            kind = .route(summary ?? "", message?.text)
        case .authError(let auth, _, _, _):
            switch auth {
            case .expiredAccessToken: kind = .expiredToken
            case .missingScope(let scope): kind = .missingScope(scope.requiredScope)
            default: kind = .signInRefused("\(auth)")
            }
        case .rateLimitError(let limit, _, _, _):
            kind = .rateLimited(limit.retryAfter)
        case .internalServerError(let code, let message, _):
            kind = .serverError("HTTP \(code)" + (message.map { " \($0)" } ?? ""))
        case .httpError(let code, let message, _):
            if let code, code >= 500 { kind = .serverError("HTTP \(code)") } else {
                kind = .other("HTTP \(code.map(String.init) ?? "error")" + (message.map { " \($0)" } ?? ""))
            }
        case .clientError(let client):
            if case .urlSessionError(let underlying) = client { kind = .network(underlying.localizedDescription) } else {
                kind = .other("\(client)")
            }
        default:
            kind = .other(error.description)
        }
    }

    var expiredToken: Bool { if case .expiredToken = kind { true } else { false } }

    /// Seconds to wait before trying again, or nil when trying again does not help.
    func retryAfter(attempt: Int) -> Double? {
        let backoff = Double(1 << (attempt - 1))
        switch kind {
        case .expiredToken: return 0
        case .rateLimited(let seconds): return max(Double(seconds), 1)
        case .serverError, .network: return backoff
        case .route(let summary, _): return summary.contains("too_many_write_operations") ? backoff : nil
        case .signInRefused, .missingScope, .other: return nil
        }
    }

    func vfsError(_ action: String, _ path: VFSPath, to: VFSPath?, email: String) -> Error {
        switch kind {
        case .route(let summary, let message):
            let parts = summary.split(separator: "/").map(String.init)
            let blamed = parts.first == "to" ? (to ?? path) : path
            if parts.contains("not_found") { return VFSError.notFound(blamed) }
            if parts.contains("conflict") { return VFSError.alreadyExists(blamed) }
            if parts.contains("not_folder") { return VFSError.notADirectory(blamed) }
            if parts.contains("no_write_permission") || parts.contains("no_permission") {
                return VFSError.permissionDenied(blamed)
            }
            if parts.contains("insufficient_space") {
                return VFSError.failed("\(action) failed: the Dropbox of \(email) is full")
            }
            if parts.contains("disallowed_name") {
                return VFSError.failed("\(action) failed: Dropbox does not allow the name \(blamed.name)")
            }
            return VFSError.failed("\(action) failed: \(message ?? summary)")
        case .expiredToken, .signInRefused:
            return VFSError.failed("Dropbox no longer accepts the sign-in of \(email). Disconnect and connect again to sign in.")
        case .missingScope:
            return VFSError.failed("\(action) failed: the sign-in of \(email) does not allow it yet. Disconnect and connect again, then allow Basil in the browser.")
        case .rateLimited:
            return VFSError.failed("\(action) failed: Dropbox asks Basil to slow down. Try again in a moment.")
        case .serverError(let text):
            return VFSError.failed("\(action) failed: Dropbox had a problem (\(text))")
        case .network(let text):
            return VFSError.failed("\(action) failed: \(text)")
        case .other(let text):
            return VFSError.failed("\(action) failed: \(text)")
        }
    }
}

/// A file being read: ranged downloads of the revision current when it was opened, 8 MiB at a
/// time, with the next window fetched while the current one is used.
actor DropboxReadFile: ReadableFile {
    static let window: Int64 = 8 << 20

    let path: VFSPath
    let revision: String
    let size: Int64
    let provider: DropboxProvider
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private var next: (start: Int64, task: Task<Data, Error>)?

    init(path: VFSPath, revision: String, size: Int64, provider: DropboxProvider) {
        self.path = path
        self.revision = revision
        self.size = size
        self.provider = provider
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        var result = Data()
        var position = offset
        let end = min(offset + Int64(count), size)
        while position < end {
            if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
                try await load(position)
            }
            let from = Int(position - bufferStart)
            let to = Int(min(end - bufferStart, Int64(buffer.count)))
            guard to > from else { break }
            result.append(buffer.subdata(in: from..<to))
            position += Int64(to - from)
        }
        return result
    }

    /// Makes the window holding `offset` current (the prefetched one when it is that).
    private func load(_ offset: Int64) async throws {
        let start = offset / Self.window * Self.window
        if let next, next.start == start {
            self.next = nil
            buffer = try await next.task.value
        } else {
            next?.task.cancel()
            next = nil
            buffer = try await fetch(start)
        }
        bufferStart = start
        let following = start + Self.window
        if following < size { next = (following, Task { try await self.fetch(following) }) }
    }

    private func fetch(_ start: Int64) async throws -> Data {
        try await provider.download(path, revision: revision, range: start..<min(start + Self.window, size))
    }

    func close() async {
        next?.task.cancel()
        next = nil
        buffer = Data()
    }
}

/// The copy engine's partial file: written from the start (no random access), uploaded in
/// parts of 8 MiB through an upload session, and committed when its metadata is applied (the
/// engine does that after the last write, in both copy modes, and the commit carries the date)
/// or when it is synchronized. A failed commit throws there. A file closed before that (the
/// copy failed or is written again) is never committed; Dropbox drops the session.
actor DropboxWriteFile: WritableFile {
    static let part = 8 << 20

    nonisolated let path: VFSPath
    let provider: DropboxProvider
    private var buffer = Data()
    private var session: String?
    private var uploaded: UInt64 = 0
    private var written: Int64 = 0
    private var modified: Date?
    private var committed = false
    private var closed = false

    init(path: VFSPath, provider: DropboxProvider) {
        self.path = path
        self.provider = provider
    }

    func write(_ data: Data, at offset: Int64) async throws {
        guard offset == written else { throw VFSError.unsupported("writing in the middle of a file in Dropbox") }
        guard !committed, !closed else { throw VFSError.failed("The upload of \(path.name) has already ended") }
        buffer.append(data)
        written += Int64(data.count)
        while buffer.count >= Self.part { try await send(Self.part) }
    }

    /// Uploads the first `count` buffered bytes as the next part of the session.
    private func send(_ count: Int) async throws {
        let part = buffer.prefix(count)
        let hash = DropboxContentHash.of(part)
        let client = provider.client
        let action = "Uploading \(path.name)"
        if let session {
            let cursor = Files.UploadSessionCursor(sessionId: session, offset: uploaded)
            _ = try await provider.call(action, path) {
                client.files.uploadSessionAppendV2(cursor: cursor, contentHash: hash, input: Data(part))
            }
        } else {
            let started = try await provider.call(action, path) {
                client.files.uploadSessionStart(contentHash: hash, input: Data(part))
            }
            session = started.sessionId
        }
        uploaded += UInt64(count)
        buffer.removeFirst(count)
    }

    func truncate(to length: Int64) async throws {
        guard length == written, !committed else { throw VFSError.unsupported("cutting a file short in Dropbox") }
    }

    /// Commits the upload: one upload call for a small file, otherwise the session's last part
    /// and its commit. Dropbox refuses a name that exists (mode add, no automatic renaming).
    private func commit() async throws {
        guard !committed else { return }
        let client = provider.client
        let target = DropboxProvider.api(path)
        let hash = DropboxContentHash.of(buffer)
        let rest = buffer
        let action = "Uploading \(path.name)"
        // Dropbox keeps whole seconds.
        let date = modified.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        if let session {
            let cursor = Files.UploadSessionCursor(sessionId: session, offset: uploaded)
            let commit = Files.CommitInfo(path: target, mode: .add, autorename: false, clientModified: date, mute: true)
            _ = try await provider.call(action, path) {
                client.files.uploadSessionFinish(cursor: cursor, commit: commit, contentHash: hash, input: rest)
            }
        } else {
            _ = try await provider.call(action, path) {
                client.files.upload(path: target, mode: .add, autorename: false, clientModified: date, mute: true,
                                    contentHash: hash, input: rest)
            }
        }
        uploaded += UInt64(rest.count)
        buffer = Data()
        committed = true
        provider.uncommitted.withLock { _ = $0.remove(path.path.lowercased()) }
    }

    func synchronize() async throws { try await commit() }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        if committed {
            return metadata.modified == nil ? [] : ["Dropbox keeps the upload time as its date"]
        }
        if let time = metadata.modified {
            modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
        try await commit()
        return []
    }

    func close() async {
        closed = true
        buffer = Data()
    }
}

/// What the queue log notes about this provider in secure copy mode.
extension DropboxProvider {
    public var destinationCaveats: [String] {
        ["Replacing an existing file on Dropbox deletes it first (Dropbox has no atomic replace); it stays restorable on dropbox.com."]
    }
}
