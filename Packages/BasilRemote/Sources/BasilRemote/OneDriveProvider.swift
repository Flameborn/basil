import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization

extension ProviderID {
    public static let oneDrive = ProviderID("onedrive")
}

/// One Microsoft account's OneDrive (personal, or work or school), through Basil's own client
/// for Microsoft Graph v1.0.
///
/// "/" is the top of the user's drive ("My files"). Shared folders the user added there
/// ("Add shortcut to My files") are links to folders in other drives: opening one shows the
/// folder, deleting or moving it changes only the link. Names are unique in a folder (without
/// regard to case), so a path is looked up one name at a time relative to its folder's ID; what
/// a path names is kept for a minute (`cacheLifetime`), but every read of an item's state
/// (fingerprint, metadata, opening) asks OneDrive by ID, so the copy engine sees every change:
/// the fingerprint carries the content tag (cTag), which changes with the content.
///
/// OneDrive has no random-access writes and no atomic replacing rename: the copy engine uploads
/// each partial file from the start (see `OneDriveWriteFile`), checked by size and QuickXorHash;
/// replacing moves the old item to the recycle bin first. Copies inside a drive are server-side,
/// moves are renames. F8 moves to the recycle bin; Shift+F8 deletes for good where OneDrive
/// allows it (work and school accounts) and goes to the recycle bin otherwise. Folders are not
/// watched.
public final class OneDriveProvider: WritableProvider, ConnectedProvider, SharedLinkProvider, @unchecked Sendable {
    public let location: ProviderLocation
    let client: HTTPClient
    let tokens: MicrosoftTokens
    let hosts: MicrosoftHosts
    public let email: String
    public let displayName: String
    public let signedInTarget: RemoteTarget?
    /// The user's drive and its top folder.
    let driveID: String
    let rootID: String
    /// A work or school account (OneDrive for Business).
    let business: Bool

    /// How long the path of a listed item is trusted without asking again.
    static let cacheLifetime: TimeInterval = 60
    private let refs = Mutex<[String: (ref: OneDriveRef, time: Date)]>([:])
    /// Files created and not uploaded yet (their paths); removing one only forgets it.
    let uncommitted = Mutex<Set<String>>([])

    public var connectionTitle: String { "OneDrive (\(email))" }
    public var homeDirectory: VFSPath { VFSPath(location: location, path: "/") }
    public var capabilities: ProviderCapabilities {
        [.read, .write, .randomAccessRead, .rename, .clone, .setDates, .trash]
    }

    init(client: HTTPClient, tokens: MicrosoftTokens, hosts: MicrosoftHosts, email: String, displayName: String,
         driveID: String, rootID: String, business: Bool, signedInTarget: RemoteTarget?) {
        self.client = client
        self.tokens = tokens
        self.hosts = hosts
        self.email = email
        self.displayName = displayName
        self.driveID = driveID
        self.rootID = rootID
        self.business = business
        self.signedInTarget = signedInTarget
        location = ProviderLocation(provider: .oneDrive, instance: email)
    }

    public func disconnect() async { client.close() }

    var rootRef: OneDriveRef {
        OneDriveRef(kind: .folder, ownDrive: driveID, ownID: rootID, contentDrive: driveID, contentID: rootID, isRoot: true)
    }

    // MARK: Calls

    /// A Graph address ("/drives/x/items/y").
    func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var text = hosts.graph + "/v1.0" + path
        if !query.isEmpty {
            text += "?" + query.map { "\($0.0)=\(GoogleAuth.formEncode($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    func itemPath(_ drive: String, _ id: String) -> String {
        "/drives/\(GraphPath.encode(drive))/items/\(GraphPath.encode(id))"
    }

    /// The address of the item named `name` in a folder (it need not exist yet).
    func childPath(_ folder: OneDriveRef, _ name: String) -> String {
        itemPath(folder.contentDrive, folder.contentID) + ":/" + GraphPath.encode(name) + ":"
    }

    /// Sends a request with the account's access token: again with a fresh token after a 401,
    /// and after a rate limit (429, waiting as long as Retry-After says) for requests that are
    /// not sent again by the client itself. Other errors come back as responses.
    func send(_ method: String, _ url: URL, json: [String: Any]? = nil, body: Data? = nil,
              headers: [String: String] = [:], retry: Bool = true) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let token: String
            do { token = try await tokens.current() } catch let error as MicrosoftAuthError {
                if error.invalidGrant {
                    throw VFSError.failed("Microsoft no longer accepts Basil's sign-in for \(email). Disconnect and connect again.")
                }
                throw VFSError.failed(error.message)
            }
            var all = headers
            all["Authorization"] = "Bearer \(token)"
            var data = body
            if let json {
                all["Content-Type"] = "application/json"
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
                throw VFSError.failed("OneDrive no longer accepts the sign-in of \(email). Disconnect and connect again.")
            } catch is UntrustedCertificate {
                throw VFSError.failed("The connection to OneDrive is not trusted by macOS")
            }
            if !retry, attempt < 5, response.status == 429 || response.status == 503 {
                let wait = response.header("Retry-After").flatMap(Double.init) ?? Double(1 << (attempt - 1))
                try await Task.sleep(for: .seconds(min(wait, 60)))
                continue
            }
            return response
        }
    }

    /// A refused request in VFS terms.
    func failure(_ response: HTTPResponse, _ action: String, _ path: VFSPath) -> Error {
        let problem = GraphProblem(response)
        // Personal Vault: only Microsoft's own apps can unlock it, Graph answers this for it.
        if problem.message.lowercased().contains("objecthandle is invalid") {
            return VFSError.failed("\(path.name) can't be opened by other apps. Use onedrive.com or the OneDrive app.")
        }
        switch (response.status, problem.code) {
        case (404, _), (_, "itemNotFound"):
            return VFSError.notFound(path)
        case (409, _), (_, "nameAlreadyExists"):
            return VFSError.alreadyExists(path)
        case (507, _), (_, "quotaLimitReached"), (_, "insufficientStorage"):
            return VFSError.failed("\(action) failed: there is no space left in OneDrive")
        case (423, _), (_, "resourceLocked"):
            return VFSError.failed("\(action) failed: \(path.name) is locked in OneDrive (open or checked out elsewhere)")
        case (403, _), (_, "accessDenied"):
            return VFSError.permissionDenied(path)
        default:
            return VFSError.failed("\(action) failed: \(problem.message)")
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse, _ action: String, _ path: VFSPath) throws -> T {
        guard response.isSuccess else { throw failure(response, action, path) }
        do { return try JSONDecoder().decode(type, from: response.body) } catch {
            throw VFSError.failed("\(action) failed: OneDrive sent an answer Basil cannot read")
        }
    }

    /// The current metadata of an item by ID.
    func get(_ drive: String, _ id: String, _ path: VFSPath) async throws -> GraphItem {
        let response = try await send("GET", url(itemPath(drive, id), [("$select", GraphItem.select)]))
        return try decode(GraphItem.self, response, "Reading \(path.displayName)", path)
    }

    private struct Page: Decodable {
        var value: [GraphItem]?
        var nextLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    /// The items of a folder (every page), or the first `limit`.
    func items(in drive: String, _ id: String, limit: Int? = nil, _ action: String, _ path: VFSPath) async throws -> [GraphItem] {
        var result: [GraphItem] = []
        var next: URL? = url(itemPath(drive, id) + "/children", [("$select", GraphItem.select), ("$top", String(limit ?? 1000))])
        while let address = next {
            let page = try decode(Page.self, try await send("GET", address), action, path)
            result += page.value ?? []
            next = limit == nil ? page.nextLink.flatMap(URL.init(string:)) : nil
            try Task.checkCancellation()
        }
        return result
    }

    // MARK: Paths

    private func cached(_ path: VFSPath) -> OneDriveRef? {
        refs.withLock { map in
            guard let entry = map[path.path] else { return nil }
            if Date().timeIntervalSince(entry.time) > Self.cacheLifetime {
                map[path.path] = nil
                return nil
            }
            return entry.ref
        }
    }

    func remember(_ path: VFSPath, _ ref: OneDriveRef) {
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

    /// What a path names, from the cache or by asking OneDrive for that name in its folder.
    func ref(_ path: VFSPath) async throws -> OneDriveRef {
        if path.isRoot { return rootRef }
        if let cached = cached(path) { return cached }
        guard let parentPath = path.parent else { throw VFSError.notFound(path) }
        let parent = try await ref(parentPath)
        guard parent.isFolderLike else { throw VFSError.notADirectory(parentPath) }
        guard let found = try await existing(path, in: parent) else { throw VFSError.notFound(path) }
        remember(path, found)
        return found
    }

    func lookUp(_ path: VFSPath) async throws -> OneDriveRef? {
        do { return try await ref(path) } catch VFSError.notFound { return nil }
    }

    /// The item named like `path` in `parent` right now (asked of OneDrive, not the cache), or nil.
    func existing(_ path: VFSPath, in parent: OneDriveRef) async throws -> OneDriveRef? {
        let response = try await send("GET", url(childPath(parent, path.name), [("$select", GraphItem.select)]))
        if response.status == 404 { return nil }
        let item = try decode(GraphItem.self, response, "Checking \(path.name)", path)
        return OneDriveRef.of(item, drive: parent.contentDrive)
    }

    /// A path's item and its current metadata (a link's target for a link). An item the cache
    /// named that is gone is looked up again once.
    func current(_ path: VFSPath) async throws -> (OneDriveRef, GraphItem) {
        for attempt in 0..<2 {
            let ref = try await ref(path)
            do {
                return (ref, try await get(ref.contentDrive, ref.contentID, path))
            } catch VFSError.notFound where attempt == 0 {
                forget(path)
            }
        }
        throw VFSError.notFound(path)
    }

    /// The items of a folder, with their paths; remembered for `ref`.
    func children(of ref: OneDriveRef, at directory: VFSPath) async throws -> [(path: VFSPath, ref: OneDriveRef, item: FileItem)] {
        let action = "Listing \(directory.isRoot ? "OneDrive" : directory.name)"
        let found = try await items(in: ref.contentDrive, ref.contentID, action, directory)
        let result = found.compactMap { item -> (path: VFSPath, ref: OneDriveRef, item: FileItem)? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let child = OneDriveRef.of(item, drive: ref.contentDrive)
            let path = directory.appending(name)
            return (path, child, self.item(child, at: path))
        }
        let prefix = directory.isRoot ? "/" : directory.path + "/"
        let now = Date()
        refs.withLock { map in
            for key in map.keys where key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/") { map[key] = nil }
            for entry in result { map[entry.path.path] = (entry.ref, now) }
        }
        return result
    }

    func item(_ ref: OneDriveRef, at path: VFSPath, content: GraphItem? = nil) -> FileItem {
        let content = content ?? ref.content
        let hidden = path.name.hasPrefix(".")
        let id = Self.number(ref.contentDrive + "!" + ref.contentID)
        switch ref.kind {
        case .folder:
            return FileItem(path: path, kind: .directory, modified: content?.modified, created: content?.created,
                            isHidden: hidden, fileID: id)
        case .folderLink:
            return FileItem(path: path, kind: .symlink(target: content == nil ? .broken : .directory),
                            modified: content?.modified, created: content?.created, isHidden: hidden, fileID: id)
        case .file:
            return FileItem(path: path, kind: .file, size: content?.size ?? 0, modified: content?.modified,
                            created: content?.created, isHidden: hidden, fileID: id)
        }
    }

    /// A stable 64-bit number for an ID (FNV-1a).
    static func number(_ text: String) -> UInt64 { GoogleDriveProvider.number(text) }

    /// The folder new items of `path` go into.
    func writableFolder(_ folder: VFSPath, for path: VFSPath) async throws -> OneDriveRef {
        if let problem = GraphPath.problem(with: path.name) { throw VFSError.failed("\(path.name) cannot be made: \(problem)") }
        let ref = try await ref(folder)
        guard ref.isFolderLike else { throw VFSError.notADirectory(folder) }
        return ref
    }

    // MARK: Shared links

    /// The item's OneDrive web address: it opens for everyone the item is shared with; Basil
    /// does not change who that is.
    public func sharedLink(for path: VFSPath) async throws -> URL {
        let (_, item) = try await current(path)
        guard let text = item.webUrl, let link = URL(string: text) else {
            throw VFSError.failed("OneDrive has no link for \(path.displayName)")
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
        let (ref, item) = try await current(path)
        return self.item(ref, at: path, content: item)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: WritableProvider

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let (ref, item) = try await current(path)
        switch ref.kind {
        case .folder:
            return FileFingerprint(kind: .directory, size: 0, fileID: Self.number(ref.contentDrive + "!" + ref.contentID))
        case .folderLink:
            return FileFingerprint(kind: .symlink, size: 0, fileID: Self.number(ref.ownDrive + "!" + ref.ownID))
        case .file:
            // The content tag changes with every new content, the hash follows the content.
            let identity = [ref.contentDrive, item.id, item.cTag ?? item.eTag ?? "", item.file?.hashes?.quickXorHash ?? ""]
                .joined(separator: " ")
            return FileFingerprint(kind: .file, size: item.size ?? 0, modifiedNanos: item.serverModified.map(Self.nanos),
                                   fileID: Self.number(identity))
        }
    }

    static func nanos(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let (_, item) = try await current(path)
        var metadata = FileMetadata()
        if let date = item.modified { metadata.modified = GoogleDriveProvider.timespec(date) }
        if let date = item.created { metadata.created = GoogleDriveProvider.timespec(date) }
        return metadata
    }

    /// OneDrive keeps a modification date for files and folders (fileSystemInfo); the rest of
    /// the metadata has no place there and is left out quietly. A link's target is not changed.
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        guard let modified = metadata.modified else { return [] }
        let ref = try await ref(path)
        guard !ref.isRoot, !ref.isLink else { return [] }
        let date = DriveDate.format(seconds: modified.tv_sec, nanos: modified.tv_nsec)
        let response = try await send("PATCH", url(itemPath(ref.ownDrive, ref.ownID), [("$select", "id")]),
                                      json: ["fileSystemInfo": ["lastModifiedDateTime": date]])
        return response.isSuccess ? [] : ["could not set the date (\(GraphProblem(response).message))"]
    }

    /// The drive holding `path`, or the drive of the folder it would go into (a copy's target
    /// does not exist yet).
    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        var current = path
        while true {
            if let ref = try await lookUp(current) {
                return "onedrive:\(email):" + (current == path ? ref.ownDrive : ref.contentDrive)
            }
            guard let parent = current.parent else { return nil }
            current = parent
        }
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        let (ref, item) = try await current(path)
        guard ref.kind == .file else { throw VFSError.failed("\(path.displayName) is a folder") }
        let content = url(itemPath(ref.contentDrive, item.id) + "/content")
        let drive = ref.contentDrive
        let id = item.id
        let client = client
        return HTTPReadFile(name: path.name, start: { offset in
            // Graph answers with a redirect to a short-lived download address on another host,
            // which carries its own authorisation: no token is sent there.
            let answer = try await self.send("GET", content)
            guard [301, 302, 303, 307, 308].contains(answer.status), let location = answer.header("Location"),
                  let target = URL(string: location) else {
                throw self.failure(answer, "Reading \(path.name)", path)
            }
            return client.download(target, from: offset)
        }, currentSize: { try? await self.get(drive, id, path).size },
           failure: { self.failure($0, "Reading \(path.name)", path) })
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        guard let folder = path.parent else { throw VFSError.alreadyExists(path) }
        let parent = try await writableFolder(folder, for: path)
        if try await existing(path, in: parent) != nil { throw VFSError.alreadyExists(path) }
        uncommitted.withLock { _ = $0.insert(path.path) }
        return OneDriveWriteFile(path: path, parent: parent, provider: self)
    }

    /// Renames and moves inside one drive (a move between drives is a copy and a delete, which
    /// the copy engine does when this throws `.unsupported`). Replacing moves the old file to
    /// the recycle bin first; folders are never replaced.
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        let source = try await ref(from)
        guard !source.isRoot, let fromFolder = from.parent, let toFolder = to.parent else { throw VFSError.permissionDenied(from) }
        let fromParent = try await ref(fromFolder)
        let toParent = try await writableFolder(toFolder, for: to)
        let moving = fromParent.contentID != toParent.contentID || fromParent.contentDrive != toParent.contentDrive
        if moving, source.ownDrive != toParent.contentDrive { throw VFSError.unsupported("moving between drives") }
        if let target = try await existing(to, in: toParent), target.ownID != source.ownID {
            guard replacing, target.kind == .file else { throw VFSError.alreadyExists(to) }
            let response = try await send("DELETE", url(itemPath(target.ownDrive, target.ownID)), retry: false)
            guard response.isSuccess || response.status == 404 else { throw failure(response, "Replacing \(to.name)", to) }
            forget(to)
        }
        var body: [String: Any] = ["name": to.name]
        if moving { body["parentReference"] = ["id": toParent.contentID] }
        let address = url(itemPath(source.ownDrive, source.ownID), [("$select", GraphItem.select)])
        var response = try await send("PATCH", address, json: body, retry: false)
        if response.status == 409, !moving, from.name.lowercased() == to.name.lowercased() {
            // A change of case only: through a temporary name.
            let temporary = try await send("PATCH", address, json: ["name": ".basil-rename-" + UUID().uuidString], retry: false)
            guard temporary.isSuccess else { throw failure(temporary, "Renaming \(from.name)", from) }
            response = try await send("PATCH", address, json: body, retry: false)
        }
        let item = try decode(GraphItem.self, response, "Renaming \(from.name)", from)
        forget(from)
        remember(to, OneDriveRef.of(item, drive: toParent.contentDrive))
    }

    /// A server-side copy of a file. OneDrive copies in the background; Basil waits for it.
    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        let source = try await ref(from)
        guard source.kind == .file else { throw VFSError.unsupported("copying folders on OneDrive") }
        guard let toFolder = to.parent else { throw VFSError.alreadyExists(to) }
        let toParent = try await writableFolder(toFolder, for: to)
        if try await existing(to, in: toParent) != nil { throw VFSError.alreadyExists(to) }
        let action = "Copying \(from.name)"
        let response = try await send("POST", url(itemPath(source.contentDrive, source.contentID) + "/copy",
                                                   [("@microsoft.graph.conflictBehavior", "fail")]),
                                      json: ["parentReference": ["driveId": toParent.contentDrive, "id": toParent.contentID],
                                             "name": to.name], retry: false)
        guard response.isSuccess else { throw failure(response, action, to) }
        if response.status == 202, let location = response.header("Location"), let monitor = URL(string: location) {
            try await waitForCopy(monitor, action, to)
        }
        guard let copied = try await existing(to, in: toParent) else {
            throw VFSError.failed("\(action) failed: OneDrive did not make the copy")
        }
        remember(to, copied)
    }

    /// Asks the copy's monitor address (which needs no token) until the copy is done.
    private func waitForCopy(_ monitor: URL, _ action: String, _ path: VFSPath) async throws {
        var delay = 0.1
        while true {
            try Task.checkCancellation()
            let answer = try await client.send("GET", monitor)
            // Personal accounts send the finished copy's address with 303.
            if answer.status == 303 { return }
            let json = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any] ?? [:]
            let status = json["status"] as? String ?? ""
            switch status {
            case "completed":
                return
            case "failed", "deleted", "cancelled":
                let error = (json["error"] as? [String: Any])?["message"] as? String
                throw VFSError.failed("\(action) failed: " + (error ?? "OneDrive could not copy it"))
            default:
                guard answer.isSuccess else { throw failure(answer, action, path) }
            }
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 2)
        }
    }

    /// Deletes a file, a link or an empty folder for good (Shift+F8) where OneDrive allows it
    /// (work and school accounts); personal accounts have no permanent delete, so it goes to the
    /// recycle bin. OneDrive deletes a folder with everything in it, so a folder is checked first.
    public func remove(_ path: VFSPath) async throws {
        if uncommitted.withLock({ $0.remove(path.path) }) != nil {
            forget(path)
            if try await lookUp(path) == nil { return }
        }
        let ref = try await ref(path)
        guard !ref.isRoot else { throw VFSError.permissionDenied(path) }
        let action = "Deleting \(path.name)"
        if ref.kind == .folder {
            let inside = try await items(in: ref.ownDrive, ref.ownID, limit: 1, action, path)
            if !inside.isEmpty { throw VFSError.directoryNotEmpty(path) }
        }
        let item = itemPath(ref.ownDrive, ref.ownID)
        if business {
            let response = try await send("POST", url(item + "/permanentDelete"), retry: false)
            if response.isSuccess {
                forget(path)
                return
            }
            if response.status == 404 { throw VFSError.notFound(path) }
            // Not offered for this drive: the recycle bin below.
        }
        let response = try await send("DELETE", url(item), retry: false)
        guard response.isSuccess else { throw failure(response, action, path) }
        forget(path)
    }

    /// OneDrive's recycle bin: restorable on onedrive.com.
    public func trash(_ path: VFSPath) async throws {
        let ref = try await ref(path)
        guard !ref.isRoot else { throw VFSError.permissionDenied(path) }
        let response = try await send("DELETE", url(itemPath(ref.ownDrive, ref.ownID)), retry: false)
        guard response.isSuccess else { throw failure(response, "Moving \(path.name) to the recycle bin", path) }
        forget(path)
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        guard let folder = path.parent else { throw VFSError.alreadyExists(path) }
        let parent = try await writableFolder(folder, for: path)
        let response = try await send("POST", url(itemPath(parent.contentDrive, parent.contentID) + "/children", [("$select", GraphItem.select)]),
                                      json: ["name": path.name, "folder": [String: Any](), "@microsoft.graph.conflictBehavior": "fail"],
                                      retry: false)
        let item = try decode(GraphItem.self, response, "Making \(path.name)", path)
        remember(path, OneDriveRef.of(item, drive: parent.contentDrive))
    }

    /// OneDrive stored a file when it confirmed the upload; there is nothing to flush.
    public func synchronize(_ path: VFSPath) async throws {}

    /// A shared folder added to My files reads as a link to it; the link text names the folder.
    public func readSymlink(_ path: VFSPath) async throws -> String {
        let ref = try await ref(path)
        guard ref.kind == .folderLink else { throw VFSError.failed("\(path.name) is not a shortcut") }
        return "OneDrive shortcut to " + (ref.content?.name ?? "a shared folder")
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        throw VFSError.unsupported("making links on OneDrive")
    }
}

/// What the queue log notes about this provider in secure copy mode.
extension OneDriveProvider {
    public var destinationCaveats: [String] {
        ["Replacing an existing file on OneDrive moves it to the recycle bin first (OneDrive has no atomic replace)."]
    }
}
