import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization

extension ProviderID {
    public static let googleDrive = ProviderID("gdrive")
}

/// One Google account's Drive, through Basil's own client for the Drive API v3.
///
/// Drive names items by ID, not by path, and allows several items of one name in a folder. Basil
/// maps paths to IDs by listing folders: "/" holds the places My Drive, Shared with me and
/// Shared drives; extra items of one name are listed as "notes (2).txt" (the oldest keeps the
/// name); Google Docs, Sheets and Slides are listed and read as their Office export
/// ("Report.docx"), Drawings as PDF; a shortcut to a file reads as the target, a shortcut to a
/// folder is a link to that folder (so deleting or moving it never reaches the target's files).
/// What a path names is kept for a minute (`cacheLifetime`), but every read of an item's state
/// (fingerprint, metadata, opening) asks Drive by ID, so the copy engine sees every change: the
/// fingerprint carries the item's version and MD5.
///
/// Drive has no random-access writes and no atomic replacing rename: the copy engine uploads
/// each partial file from the start (small files in one request, larger ones in a resumable
/// upload of 8 MB chunks), checked by size and MD5 once Drive has it; replacing moves the old
/// item to the trash first. Copies inside one drive are server-side, moves are renames. Folders
/// are not watched.
public final class GoogleDriveProvider: WritableProvider, ConnectedProvider, SharedLinkProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let client: HTTPClient
    let tokens: GoogleTokens
    let hosts: GoogleHosts
    public let email: String
    public let displayName: String
    public let signedInTarget: RemoteTarget?
    /// The ID of My Drive's top folder.
    let rootID: String

    /// How long the path of a listed item is trusted without listing its folder again.
    static let cacheLifetime: TimeInterval = 60
    private let refs = Mutex<[String: (ref: DriveRef, time: Date)]>([:])
    /// Recent exports of Google documents by ID and version (at most `exportsKept`).
    private let exports = Mutex<[(key: String, data: Data)]>([])
    static let exportsKept = 3
    /// Files created and not uploaded yet (their paths); removing one only forgets it.
    let uncommitted = Mutex<Set<String>>([])

    public var connectionTitle: String { "Google Drive (\(email))" }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/" + DriveNames.myDrive) }
    public var capabilities: ProviderCapabilities {
        [.read, .write, .randomAccessRead, .rename, .clone, .setDates, .trash]
    }

    init(client: HTTPClient, tokens: GoogleTokens, hosts: GoogleHosts, email: String, displayName: String,
         rootID: String, signedInTarget: RemoteTarget?) {
        self.client = client
        self.tokens = tokens
        self.hosts = hosts
        self.email = email
        self.displayName = displayName
        self.rootID = rootID
        self.signedInTarget = signedInTarget
        location = ProviderLocation(provider: .googleDrive, instance: email)
    }

    public func disconnect() async { client.close() }

    // MARK: Calls

    /// A Drive API address ("/files/abc"), or an upload address.
    func url(_ path: String, _ query: [(String, String)] = [], upload: Bool = false) -> URL {
        var text = hosts.api + (upload ? "/upload/drive/v3" : "/drive/v3") + path
        if !query.isEmpty {
            text += "?" + query.map { "\($0.0)=\(GoogleAuth.formEncode($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    /// Sends a request with the account's access token: again with a fresh token after a 401,
    /// and after Drive's rate limits (up to five tries). Other errors come back as responses.
    func send(_ method: String, _ url: URL, json: [String: Any]? = nil, body: Data? = nil,
              headers: [String: String] = [:], retry: Bool = true) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let token: String
            do { token = try await tokens.current() } catch let error as GoogleAuthError {
                if error.invalidGrant {
                    throw VFSError.failed("Google no longer accepts Basil's sign-in for \(email). Disconnect and connect again.")
                }
                throw VFSError.failed(error.message)
            }
            var all = headers
            all["Authorization"] = "Bearer \(token)"
            var data = body
            if let json {
                all["Content-Type"] = "application/json; charset=utf-8"
                data = try JSONSerialization.data(withJSONObject: json)
            }
            let response: HTTPResponse
            do {
                response = try await client.send(method, url, headers: all, body: data, retry: retry)
            } catch is HTTPUnauthorized {
                if attempt < 3 {
                    tokens.expire()
                    continue
                }
                throw VFSError.failed("Google Drive no longer accepts the sign-in of \(email). Disconnect and connect again.")
            } catch is UntrustedCertificate {
                throw VFSError.failed("The connection to Google Drive is not trusted by macOS")
            }
            // 429 is sent again by the client itself when `retry` allows it.
            if attempt < 5, response.status == 403 || (response.status == 429 && !retry),
               DriveProblem(response).isRateLimit {
                try await Task.sleep(for: .seconds(Double(1 << (attempt - 1)) + Double.random(in: 0...0.5)))
                continue
            }
            return response
        }
    }

    /// A refused request in VFS terms.
    func failure(_ response: HTTPResponse, _ action: String, _ path: VFSPath) -> Error {
        let problem = DriveProblem(response)
        switch (response.status, problem.reason ?? "") {
        case (404, _): return VFSError.notFound(path)
        case (_, "storageQuotaExceeded"), (_, "quotaExceeded"):
            return VFSError.failed("\(action) failed: there is no space left in Google Drive")
        case (_, "exportSizeLimitExceeded"):
            return VFSError.failed("\(action) failed: Google exports documents only up to 10 MB")
        case (_, "cannotDownloadAbusiveFile"):
            return VFSError.failed("\(action) failed: Google flagged \(path.name) as harmful and does not hand it out")
        case (403, "insufficientFilePermissions"), (403, "forbidden"), (403, "insufficientPermissions"),
             (403, "appNotAuthorizedToFile"):
            return VFSError.permissionDenied(path)
        default:
            return VFSError.failed("\(action) failed: \(problem.message)")
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse, _ action: String, _ path: VFSPath) throws -> T {
        guard response.isSuccess else { throw failure(response, action, path) }
        do { return try JSONDecoder().decode(type, from: response.body) } catch {
            throw VFSError.failed("\(action) failed: Google Drive sent an answer Basil cannot read")
        }
    }

    /// The current metadata of an item by ID.
    func get(_ id: String, _ path: VFSPath) async throws -> DriveFile {
        let response = try await send("GET", url("/files/\(id)", [("fields", DriveFile.fields), ("supportsAllDrives", "true")]))
        return try decode(DriveFile.self, response, "Reading \(path.displayName)", path)
    }

    private struct Page: Decodable {
        var files: [DriveFile]?
        var nextPageToken: String?
    }

    /// Every item a query finds (all pages), or the first `limit`.
    func files(_ query: String, driveID: String?, limit: Int? = nil, _ action: String, _ path: VFSPath) async throws -> [DriveFile] {
        var result: [DriveFile] = []
        var token: String?
        repeat {
            var parameters = [("q", query), ("fields", "nextPageToken,files(\(DriveFile.fields))"),
                              ("pageSize", String(limit ?? 1000)), ("supportsAllDrives", "true"),
                              ("includeItemsFromAllDrives", "true")]
            if let driveID { parameters += [("corpora", "drive"), ("driveId", driveID)] }
            if let token { parameters.append(("pageToken", token)) }
            let page = try decode(Page.self, try await send("GET", url("/files", parameters)), action, path)
            result += page.files ?? []
            token = limit == nil ? page.nextPageToken : nil
            try Task.checkCancellation()
        } while token != nil
        return result
    }

    // MARK: Paths

    private func cached(_ path: VFSPath) -> DriveRef? {
        refs.withLock { map in
            guard let entry = map[path.path] else { return nil }
            if Date().timeIntervalSince(entry.time) > Self.cacheLifetime {
                map[path.path] = nil
                return nil
            }
            return entry.ref
        }
    }

    func remember(_ path: VFSPath, _ ref: DriveRef) {
        refs.withLock { $0[path.path] = (ref, Date()) }
    }

    /// Forgets a path and everything below it.
    func forget(_ path: VFSPath) {
        let prefix = path.path + "/"
        refs.withLock { map in
            map[path.path] = nil
            for key in map.keys where key.hasPrefix(prefix) { map[key] = nil }
        }
    }

    /// What a path names, from the cache or by listing its folder.
    func ref(_ path: VFSPath) async throws -> DriveRef {
        if path.isRoot { return DriveRef(kind: .top) }
        if let cached = cached(path) { return cached }
        guard let parentPath = path.parent else { throw VFSError.notFound(path) }
        let parent = try await ref(parentPath)
        guard parent.isFolderLike else { throw VFSError.notADirectory(parentPath) }
        let children = try await children(of: parent, at: parentPath)
        guard let found = children.first(where: { $0.path == path }) else { throw VFSError.notFound(path) }
        return found.ref
    }

    func lookUp(_ path: VFSPath) async throws -> DriveRef? {
        do { return try await ref(path) } catch VFSError.notFound { return nil }
    }

    /// A path's item and its current metadata (nil for the places). An item the cache named
    /// that is gone or trashed is looked up again once.
    func current(_ path: VFSPath) async throws -> (DriveRef, DriveFile?) {
        for attempt in 0..<2 {
            let ref = try await ref(path)
            guard let id = ref.contentID, !ref.isPlace else { return (ref, nil) }
            do {
                let file = try await get(id, path)
                if file.trashed == true { throw VFSError.notFound(path) }
                return (ref, file)
            } catch VFSError.notFound where attempt == 0 {
                forget(path)
            }
        }
        throw VFSError.notFound(path)
    }

    /// The items of a folder or place, with their names in Basil; remembered for `ref`.
    func children(of ref: DriveRef, at directory: VFSPath) async throws -> [(path: VFSPath, ref: DriveRef, item: FileItem)] {
        let action = "Listing \(directory.isRoot ? "Google Drive" : directory.name)"
        var named: [(String, DriveRef)]
        switch ref.kind {
        case .top:
            named = [
                (DriveNames.myDrive, DriveRef(kind: .folder, ownID: rootID, contentID: rootID, volume: "my", isRoot: true)),
                (DriveNames.sharedWithMe, DriveRef(kind: .sharedWithMe)),
                (DriveNames.sharedDrives, DriveRef(kind: .sharedDrives)),
            ]
        case .sharedDrives:
            let drives = try await sharedDrives(action, directory)
            named = DriveNames.unique(drives.map { drive in
                (name: drive.name, folder: true, created: nil as Date?, id: drive.id,
                 value: DriveRef(kind: .folder, ownID: drive.id, contentID: drive.id, volume: drive.id, driveID: drive.id, isRoot: true))
            })
        case .sharedWithMe:
            let found = try await files("sharedWithMe = true and trashed = false", driveID: nil, action, directory)
            named = await name(found, volume: "shared")
        case .folder, .folderShortcut:
            guard let id = ref.contentID else { throw VFSError.notFound(directory) }
            let found = try await files("\(DriveNames.quoted(id)) in parents and trashed = false", driveID: ref.driveID, action, directory)
            named = await name(found, volume: ref.volume)
        case .file:
            throw VFSError.notADirectory(directory)
        }
        let result = named.map { name, child in
            let path = directory.appending(name)
            return (path: path, ref: child, item: item(child, at: path))
        }
        let prefix = directory.isRoot ? "/" : directory.path + "/"
        let now = Date()
        refs.withLock { map in
            for key in map.keys where key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/") { map[key] = nil }
            for entry in result { map[entry.path.path] = (entry.ref, now) }
        }
        return result
    }

    private struct DriveList: Decodable {
        struct Drive: Decodable { var id: String; var name: String }
        var drives: [Drive]?
        var nextPageToken: String?
    }

    private func sharedDrives(_ action: String, _ path: VFSPath) async throws -> [DriveList.Drive] {
        var result: [DriveList.Drive] = []
        var token: String?
        repeat {
            var parameters = [("pageSize", "100"), ("fields", "nextPageToken,drives(id,name)")]
            if let token { parameters.append(("pageToken", token)) }
            let page = try decode(DriveList.self, try await send("GET", url("/drives", parameters)), action, path)
            result += page.drives ?? []
            token = page.nextPageToken
        } while token != nil
        return result
    }

    /// Basil's names for the items of a listing: shortcuts resolved to their targets, Google
    /// documents with their export's extension, extra items of one name numbered.
    private func name(_ found: [DriveFile], volume: String) async -> [(String, DriveRef)] {
        let targets = await shortcutTargets(found)
        let entries = found.map { file -> (name: String, folder: Bool, created: Date?, id: String, value: DriveRef) in
            let target = file.shortcutDetails?.targetId.flatMap { targets[$0] }
            let (name, ref) = Self.describe(file, target: target, volume: volume)
            return (name: name, folder: ref.kind != .file, created: file.created, id: file.id, value: ref)
        }
        return DriveNames.unique(entries)
    }

    /// The targets of the shortcuts among `found`, eight at a time; targets Basil cannot read
    /// are left out (those shortcuts cannot be read either).
    private func shortcutTargets(_ found: [DriveFile]) async -> [String: DriveFile] {
        let ids = Array(Set(found.compactMap { $0.isShortcut ? $0.shortcutDetails?.targetId : nil }))
        guard !ids.isEmpty else { return [:] }
        var result: [String: DriveFile] = [:]
        let placeholder = VFSPath(location: location, path: "/")
        await withTaskGroup(of: (String, DriveFile?).self) { group in
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { (id, try? await self.get(id, placeholder)) }
            }
            for _ in 0..<min(8, ids.count) { add() }
            for await (id, file) in group {
                if let file, file.trashed != true { result[id] = file }
                add()
            }
        }
        return result
    }

    /// The name and reference of one listed item.
    static func describe(_ file: DriveFile, target: DriveFile?, volume: String) -> (String, DriveRef) {
        let contentType = file.isShortcut ? (target?.mimeType ?? file.shortcutDetails?.targetMimeType ?? "") : file.mimeType
        let kind: DriveRef.Kind
        if file.isShortcut {
            kind = contentType == DriveFile.folderType ? .folderShortcut : .file
        } else {
            kind = file.isFolder ? .folder : .file
        }
        var name = file.name
        var added: String?
        if kind == .file, DriveFile.isGoogleType(contentType), let export = DriveExport.of(contentType),
           !name.lowercased().hasSuffix("." + export.fileExtension) {
            name += "." + export.fileExtension
            added = export.fileExtension
        }
        let ref = DriveRef(kind: kind, ownID: file.id,
                           contentID: file.isShortcut ? file.shortcutDetails?.targetId : file.id,
                           mimeType: contentType, volume: file.driveId ?? volume,
                           driveID: (target ?? file).driveId, addedExtension: added,
                           content: file.isShortcut ? target : file)
        return (name, ref)
    }

    func item(_ ref: DriveRef, at path: VFSPath, content: DriveFile? = nil) -> FileItem {
        let content = content ?? ref.content
        let hidden = path.name.hasPrefix(".")
        let id = (ref.contentID ?? path.path)
        switch ref.kind {
        case .top, .sharedWithMe, .sharedDrives, .folder:
            return FileItem(path: path, kind: .directory, modified: content?.modified, created: content?.created,
                            isHidden: hidden, fileID: Self.number(id))
        case .folderShortcut:
            return FileItem(path: path, kind: .symlink(target: content == nil ? .broken : .directory),
                            modified: content?.modified, created: content?.created, isHidden: hidden, fileID: Self.number(id))
        case .file:
            // A Google document's size is that of its export, known only once it was made.
            let size: Int64? = ref.isGoogleType ? nil : (content?.byteCount ?? 0)
            return FileItem(path: path, kind: .file, size: size, modified: content?.modified, created: content?.created,
                            isHidden: hidden, fileID: Self.number(id))
        }
    }

    /// A stable 64-bit number for an ID (FNV-1a).
    static func number(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The name Drive should store for `name`: a Google document listed with an added
    /// extension keeps its name without it ("Notes.docx" stores "Notes").
    static func storedName(_ name: String, for ref: DriveRef) -> String {
        if let added = ref.addedExtension, name.lowercased().hasSuffix("." + added), name.count > added.count + 1 {
            return String(name.dropLast(added.count + 1))
        }
        return name
    }

    /// The folder new items of `path` go into.
    func writableFolder(_ folder: VFSPath, for path: VFSPath) async throws -> DriveRef {
        let ref = try await ref(folder)
        switch ref.kind {
        case .folder, .folderShortcut:
            return ref
        case .top:
            throw VFSError.failed("\(path.name) cannot be made here: the top of Google Drive holds only My Drive, Shared with me and Shared drives")
        case .sharedDrives:
            throw VFSError.failed("\(path.name) cannot be made here: shared drives are made on drive.google.com")
        case .sharedWithMe:
            throw VFSError.failed("\(path.name) cannot be made in Shared with me: open a shared folder first")
        case .file:
            throw VFSError.notADirectory(folder)
        }
    }

    /// The item listed at `path` right now (asked of Drive, not the cache), or nil. `parent` is
    /// the folder holding it.
    func existing(_ path: VFSPath, in parent: DriveRef) async throws -> DriveRef? {
        guard let parentPath = path.parent, let parentID = parent.contentID else { return nil }
        let action = "Checking \(path.name)"
        let exact = try await files("\(DriveNames.quoted(parentID)) in parents and name = \(DriveNames.quoted(path.name)) and trashed = false",
                                    driveID: parent.driveID, action, path)
        let listed = exact.map { Self.describe($0, target: nil, volume: parent.volume) }
        // A Google document named "Report" is listed as "Report.docx", not as "Report".
        if let match = listed.filter({ $0.0 == path.name }).map(\.1)
            .sorted(by: { ($0.content?.created ?? .distantPast, $0.ownID ?? "") < ($1.content?.created ?? .distantPast, $1.ownID ?? "") })
            .first {
            return match
        }
        // Names Basil made (numbered extras, exports) exist only in a full listing.
        if Self.mayBeMadeName(path.name) {
            return try await children(of: parent, at: parentPath).first { $0.path == path }?.ref
        }
        return nil
    }

    /// "notes (2).txt", or a name with the extension of an export.
    static func mayBeMadeName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["docx", "xlsx", "pptx", "pdf", "json"].contains(where: { lower.hasSuffix("." + $0) }) { return true }
        return name.range(of: #" \(\d+\)(\.[^.]*)?$"#, options: .regularExpression) != nil
    }

    // MARK: Exports

    /// A Google document's export (up to 10 MB, made by Google), kept while its version stays.
    func exportData(_ file: DriveFile, _ export: DriveExport, _ path: VFSPath) async throws -> Data {
        let key = file.id + "@" + (file.version ?? file.modifiedTime ?? "")
        if let data = exports.withLock({ $0.first { $0.key == key }?.data }) { return data }
        let response = try await send("GET", url("/files/\(file.id)/export", [("mimeType", export.mimeType)]))
        guard response.isSuccess else { throw failure(response, "Exporting \(path.name)", path) }
        exports.withLock { list in
            list.removeAll { $0.key == key }
            list.insert((key, response.body), at: 0)
            if list.count > Self.exportsKept { list.removeLast(list.count - Self.exportsKept) }
        }
        return response.body
    }

    // MARK: Shared links

    /// The item's Drive link (drive.google.com/...): it opens for everyone the item is shared
    /// with; Basil does not change who that is.
    public func sharedLink(for path: VFSPath) async throws -> URL {
        let (_, file) = try await current(path)
        guard let text = file?.webViewLink, let link = URL(string: text) else {
            throw VFSError.failed("Google Drive has no link for \(path.displayName)")
        }
        return link
    }

    // MARK: FileSystemProvider

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let ref = try await ref(directory)
                    guard ref.isFolderLike else { throw VFSError.notADirectory(directory) }
                    let items = try await children(of: ref, at: directory).map(\.item)
                    var start = 0
                    while start < items.count {
                        continuation.yield(Array(items[start..<min(start + 1000, items.count)]))
                        start += 1000
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        let (ref, file) = try await current(path)
        return item(ref, at: path, content: file)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let (ref, file) = try await current(path)
        switch ref.kind {
        case .top, .sharedWithMe, .sharedDrives, .folder:
            return FileFingerprint(kind: .directory, size: 0, fileID: Self.number(ref.contentID ?? path.path))
        case .folderShortcut:
            return FileFingerprint(kind: .symlink, size: 0, fileID: Self.number(ref.ownID ?? path.path))
        case .file:
            guard let file else { throw VFSError.notFound(path) }
            let size: Int64
            if let export = ref.export {
                size = Int64(try await exportData(file, export, path).count)
            } else {
                size = file.byteCount ?? 0
            }
            // The version goes up with every change, the MD5 follows the content.
            let identity = [file.id, file.md5Checksum ?? "", file.version ?? ""].joined(separator: " ")
            return FileFingerprint(kind: .file, size: size, modifiedNanos: file.modified.map(Self.nanos),
                                   fileID: Self.number(identity))
        }
    }

    static func nanos(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let (_, file) = try await current(path)
        var metadata = FileMetadata()
        if let date = file?.modified { metadata.modified = Self.timespec(date) }
        if let date = file?.created { metadata.created = Self.timespec(date) }
        return metadata
    }

    static func timespec(_ date: Date) -> Darwin.timespec {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int(((date.timeIntervalSince1970 - seconds) * 1e9).rounded()))
    }

    /// Drive keeps a modification date for files and folders; the rest of the metadata has no
    /// place there and is left out quietly. A shortcut's target is not changed.
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        guard let modified = metadata.modified else { return [] }
        let ref = try await ref(path)
        guard let id = ref.ownID, !ref.isPlace, !ref.isRoot, ref.ownID == ref.contentID else { return [] }
        let response = try await send("PATCH", url("/files/\(id)", [("supportsAllDrives", "true"), ("fields", "id")]),
                                      json: ["modifiedTime": DriveDate.format(seconds: modified.tv_sec, nanos: modified.tv_nsec)])
        return response.isSuccess ? [] : ["could not set the date (\(DriveProblem(response).message))"]
    }

    /// The drive holding `path`, or the folder it would go into (a copy's target does not exist yet).
    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        var current = path
        while true {
            if let ref = try await lookUp(current) { return "gdrive:\(email):\(ref.volume)" }
            guard let parent = current.parent else { return nil }
            current = parent
        }
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        let (ref, file) = try await current(path)
        guard ref.kind == .file, let file else { throw VFSError.failed("\(path.displayName) is a folder") }
        if let export = ref.export {
            return MemoryReadFile(data: try await exportData(file, export, path))
        }
        if ref.isGoogleType {
            throw VFSError.failed("\(path.name) is a \(DriveExport.typeName(ref.mimeType)) item, which Google Drive does not hand out as a file")
        }
        let id = file.id
        let address = url("/files/\(id)", [("alt", "media"), ("supportsAllDrives", "true")])
        let client = client
        let tokens = tokens
        return HTTPReadFile(name: path.name, start: { offset in
            let token = try await tokens.current()
            return client.download(address, from: offset, headers: ["Authorization": "Bearer \(token)"])
        }, currentSize: { try? await self.get(id, path).byteCount },
           failure: { self.failure($0, "Reading \(path.name)", path) })
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        guard let folder = path.parent else { throw VFSError.alreadyExists(path) }
        let parent = try await writableFolder(folder, for: path)
        if try await existing(path, in: parent) != nil { throw VFSError.alreadyExists(path) }
        uncommitted.withLock { _ = $0.insert(path.path) }
        return GoogleDriveWriteFile(path: path, parent: parent, provider: self)
    }

    /// Renames and moves inside one drive (a move between drives is a copy and a delete, which
    /// the copy engine does when this throws `.unsupported`). Replacing moves the old item to
    /// the trash first; Google documents are never replaced.
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        let source = try await ref(from)
        guard let ownID = source.ownID, !source.isRoot, !source.isPlace,
              let fromFolder = from.parent, let toFolder = to.parent else { throw VFSError.permissionDenied(from) }
        let fromParent = try await ref(fromFolder)
        let toParent = try await writableFolder(toFolder, for: to)
        let moving = fromParent.contentID != toParent.contentID
        if moving {
            guard fromParent.kind == .folder || fromParent.kind == .folderShortcut, fromParent.contentID != nil else {
                throw VFSError.unsupported("moving items out of Shared with me on Google Drive")
            }
            guard source.volume == toParent.volume else { throw VFSError.unsupported("moving between drives") }
        }
        if let target = try await existing(to, in: toParent), target.ownID != ownID {
            guard replacing, target.kind == .file else { throw VFSError.alreadyExists(to) }
            if target.isGoogleType, target.ownID == target.contentID {
                throw VFSError.failed("\(to.name) is a Google document; Basil does not replace Google documents")
            }
            try await moveToTrash(target, to)
            forget(to)
        }
        var body: [String: Any] = ["name": Self.storedName(to.name, for: source)]
        if source.kind == .file, source.ownID == source.contentID,
           let modified = (try? await get(ownID, from))?.modifiedTime {
            // Keeps the file's date (a rename is not a change of its content).
            body["modifiedTime"] = modified
        }
        var query = [("supportsAllDrives", "true"), ("fields", DriveFile.fields)]
        if moving, let add = toParent.contentID, let remove = fromParent.contentID {
            query += [("addParents", add), ("removeParents", remove)]
        }
        let response = try await send("PATCH", url("/files/\(ownID)", query), json: body, retry: false)
        let file = try decode(DriveFile.self, response, "Renaming \(from.name)", from)
        forget(from)
        if !file.isShortcut {
            let (_, ref) = Self.describe(file, target: nil, volume: toParent.volume)
            remember(to, ref)
        }
    }

    /// A server-side copy of a file (Google documents stay Google documents).
    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        let source = try await ref(from)
        guard source.kind == .file, let contentID = source.contentID else {
            throw VFSError.unsupported("copying folders on Google Drive")
        }
        guard let toFolder = to.parent else { throw VFSError.alreadyExists(to) }
        let toParent = try await writableFolder(toFolder, for: to)
        guard let parentID = toParent.contentID else { throw VFSError.permissionDenied(to) }
        if try await existing(to, in: toParent) != nil { throw VFSError.alreadyExists(to) }
        let response = try await send("POST", url("/files/\(contentID)/copy", [("supportsAllDrives", "true"), ("fields", DriveFile.fields)]),
                                      json: ["name": Self.storedName(to.name, for: source), "parents": [parentID]], retry: false)
        let file = try decode(DriveFile.self, response, "Copying \(from.name)", from)
        remember(to, Self.describe(file, target: nil, volume: toParent.volume).1)
    }

    /// Deletes a file, a shortcut or an empty folder for good (Shift+F8). Drive deletes a folder
    /// with everything in it, so a folder is checked first.
    public func remove(_ path: VFSPath) async throws {
        if uncommitted.withLock({ $0.remove(path.path) }) != nil {
            forget(path)
            if try await lookUp(path) == nil { return }
        }
        let ref = try await ref(path)
        guard let ownID = ref.ownID, !ref.isRoot, !ref.isPlace else { throw VFSError.permissionDenied(path) }
        if ref.kind == .folder {
            let inside = try await files("\(DriveNames.quoted(ownID)) in parents and trashed = false", driveID: ref.driveID,
                                         limit: 1, "Deleting \(path.name)", path)
            if !inside.isEmpty { throw VFSError.directoryNotEmpty(path) }
        }
        let response = try await send("DELETE", url("/files/\(ownID)", [("supportsAllDrives", "true")]), retry: false)
        if response.status == 403 {
            throw VFSError.failed("Google Drive does not let this account delete \(path.name) for good (in a shared drive only managers can, elsewhere only the owner); Move to Trash may work")
        }
        guard response.isSuccess else { throw failure(response, "Deleting \(path.name)", path) }
        forget(path)
    }

    /// Drive's trash: restorable on drive.google.com for 30 days.
    public func trash(_ path: VFSPath) async throws {
        let ref = try await ref(path)
        guard !ref.isRoot, !ref.isPlace else { throw VFSError.permissionDenied(path) }
        try await moveToTrash(ref, path)
        forget(path)
    }

    private func moveToTrash(_ ref: DriveRef, _ path: VFSPath) async throws {
        guard let ownID = ref.ownID else { throw VFSError.permissionDenied(path) }
        let response = try await send("PATCH", url("/files/\(ownID)", [("supportsAllDrives", "true"), ("fields", "id")]),
                                      json: ["trashed": true], retry: false)
        guard response.isSuccess else { throw failure(response, "Moving \(path.name) to the trash", path) }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        guard let folder = path.parent else { throw VFSError.alreadyExists(path) }
        let parent = try await writableFolder(folder, for: path)
        guard let parentID = parent.contentID else { throw VFSError.permissionDenied(path) }
        if try await existing(path, in: parent) != nil { throw VFSError.alreadyExists(path) }
        let response = try await send("POST", url("/files", [("supportsAllDrives", "true"), ("fields", DriveFile.fields)]),
                                      json: ["name": path.name, "mimeType": DriveFile.folderType, "parents": [parentID]], retry: false)
        let file = try decode(DriveFile.self, response, "Making \(path.name)", path)
        remember(path, Self.describe(file, target: nil, volume: parent.volume).1)
    }

    /// Drive stored a file when it confirmed the upload; there is nothing to flush.
    public func synchronize(_ path: VFSPath) async throws {}

    /// A shortcut to a folder reads as a link to it; the link text names the target.
    public func readSymlink(_ path: VFSPath) async throws -> String {
        let ref = try await ref(path)
        guard ref.kind == .folderShortcut else { throw VFSError.failed("\(path.name) is not a shortcut") }
        return "Google Drive shortcut to " + (ref.content?.name ?? "a folder")
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links on Google Drive")
    }
}

/// A file read from memory (a Google document's export).
struct MemoryReadFile: ReadableFile {
    let data: Data

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset < Int64(data.count) else { return Data() }
        let start = data.startIndex + Int(offset)
        return Data(data[start..<min(start + count, data.endIndex)])
    }

    func close() async {}
}

/// What the queue log notes about this provider in secure copy mode.
extension GoogleDriveProvider {
    public var destinationCaveats: [String] {
        ["Replacing an existing file on Google Drive moves it to the trash first (Drive has no atomic replace)."]
    }
}
