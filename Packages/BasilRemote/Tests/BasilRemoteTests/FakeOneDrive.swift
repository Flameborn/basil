import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization
@testable import BasilRemote

/// A small OneDrive for the tests: an HTTP server on 127.0.0.1 that answers Microsoft's token
/// endpoint and the Graph calls Basil makes (me, the drive, items by ID and by name in a folder,
/// listing pages, folders, renames and moves, background copies with a monitor, deletes to the
/// recycle bin and permanent ones, downloads through a redirect, simple uploads and upload
/// sessions). Items live in memory by ID, in the user's drive and in one other drive holding a
/// folder shared with the user. It checks PKCE, rotates refresh tokens (the old one stops
/// working), expires access tokens, checks the ranges and total sizes of upload pieces, and
/// counts tokens sent to the addresses that carry their own authorisation (downloads, upload
/// sessions, copy monitors). Those addresses use "localhost" instead of "127.0.0.1", so they are
/// on another host like on the real service. The browser part of signing in is `authorize(_:)`.
final class FakeOneDrive: @unchecked Sendable {
    static let clientID = "11111111-2222-3333-4444-555555555555"
    static let myDrive = "b!my-drive"
    static let otherDrive = "b!other-drive"

    struct Item {
        var id: String
        var drive: String
        var name: String
        var parent: String?
        var folder: Bool
        var data = Data()
        var created: Date
        /// fileSystemInfo's date.
        var modified: Date
        /// OneDrive's own date.
        var serverModified: Date
        var version = 1
        var deleted = false
        /// A shared folder added to My files: (drive, id) of the folder.
        var remote: (drive: String, id: String)?
        /// Personal Vault: locked to other apps, Graph refuses to list it.
        var vault = false
    }

    struct Session {
        var drive: String
        var parent: String
        var name: String
        var modified: Date?
        var data = Data()
        var total: Int?
    }

    struct State {
        var items: [String: Item] = [:]
        var codes: [String: (challenge: String, redirect: String)] = [:]
        var refreshTokens: Set<String> = []
        var accessTokens: [String: Date] = [:]
        var sessions: [String: Session] = [:]
        var monitors: [String: (id: String, asked: Int)] = [:]
        var counter = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var lifetime: TimeInterval = 3600
        /// Scopes the next sign-in grants.
        var grantedScopes = "https://graph.microsoft.com/Files.ReadWrite.All https://graph.microsoft.com/User.Read"
        /// A work or school account: permanent deletes are offered.
        var business = false
        var signIns = 0
        var refreshes = 0
        var chunks = 0
        var permanentDeletes = 0
        /// Answer this many Graph calls with 429 first.
        var rateLimited = 0
        /// Requests with an Authorization header to addresses that must not get one.
        var leakedTokens = 0
        var requests: [String] = []
        /// What the items looked like at each delta token.
        var deltas: [[String: String]] = []
    }

    let state = Mutex(State())
    let rootID = "root-id"
    let otherRootID = "other-root-id"
    let userID = "user-0001"
    let email = "tester@example.com"
    private let listener: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        state.withLock { s in
            s.items[rootID] = Item(id: rootID, drive: Self.myDrive, name: "root", parent: nil, folder: true,
                                   created: s.clock, modified: s.clock, serverModified: s.clock)
            s.items[otherRootID] = Item(id: otherRootID, drive: Self.otherDrive, name: "root", parent: nil, folder: true,
                                        created: s.clock, modified: s.clock, serverModified: s.clock)
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit { close(listener) }

    var base: String { "http://127.0.0.1:\(port)" }
    /// Addresses with their own authorisation (another host name for the same server).
    var other: String { "http://localhost:\(port)" }
    var hosts: MicrosoftHosts { MicrosoftHosts(login: base, graph: base, deltaInterval: 0.1) }

    // MARK: Items

    private func newID(_ s: inout State) -> String {
        s.counter += 1
        return "id\(s.counter)"
    }

    @discardableResult
    func put(_ name: String, in parent: String? = nil, _ data: Data, folder: Bool = false,
             created: Date? = nil, modified: Date? = nil) -> String {
        state.withLock { s in
            s.clock += 1
            let id = newID(&s)
            let parent = parent ?? rootID
            let drive = s.items[parent]?.drive ?? Self.myDrive
            s.items[id] = Item(id: id, drive: drive, name: name, parent: parent, folder: folder, data: data,
                               created: created ?? s.clock, modified: modified ?? s.clock, serverModified: s.clock)
            return id
        }
    }

    @discardableResult
    func folder(_ name: String, in parent: String? = nil) -> String { put(name, in: parent, Data(), folder: true) }

    /// Personal Vault, which Graph cannot open ("ObjectHandle is Invalid").
    @discardableResult
    func vault(_ name: String = "Personal Vault") -> String {
        let id = folder(name)
        state.withLock { $0.items[id]?.vault = true }
        return id
    }

    /// A folder in the other drive, added to the user's My files under `name`.
    @discardableResult
    func sharedFolder(_ name: String) -> (link: String, folder: String) {
        let folder = put(name, in: otherRootID, Data(), folder: true)
        let link = put(name, in: rootID, Data(), folder: true)
        state.withLock { $0.items[link]?.remote = (Self.otherDrive, folder) }
        return (link, folder)
    }

    /// Changes a file's content (a new version, a new cTag).
    func change(_ id: String, _ data: Data, modified: Date? = nil) {
        state.withLock { s in
            s.clock += 1
            s.items[id]?.data = data
            s.items[id]?.version += 1
            s.items[id]?.serverModified = s.clock
            s.items[id]?.modified = modified ?? s.clock
        }
    }

    func item(_ id: String) -> Item? { state.withLock { $0.items[id] } }

    /// The items in a folder that are not in the recycle bin.
    func children(_ parent: String? = nil) -> [Item] {
        state.withLock { s in
            s.items.values.filter { $0.parent == (parent ?? rootID) && !$0.deleted }.sorted { $0.name < $1.name }
        }
    }

    func child(_ name: String, in parent: String? = nil) -> Item? {
        children(parent).first { $0.name == name }
    }

    // MARK: Signing in

    /// What the browser does: checks the authorization request and returns the redirect back to
    /// the app with a code.
    func authorize(_ url: URL) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let scopes = Set((value("scope") ?? "").split(separator: " ").map(String.init))
        guard url.path == "/common/oauth2/v2.0/authorize", value("client_id") == Self.clientID,
              value("response_type") == "code", value("code_challenge_method") == "S256",
              scopes.isSuperset(of: ["Files.ReadWrite.All", "offline_access", "User.Read"]),
              let challenge = value("code_challenge"), let redirect = value("redirect_uri"),
              redirect.hasPrefix("http://localhost:"), redirect.hasSuffix("/onedrive"),
              let state = value("state") else { return nil }
        let code = "code-\(UUID().uuidString)"
        self.state.withLock { $0.codes[code] = (challenge, redirect) }
        return URL(string: "\(redirect)?code=\(code)&state=\(state)")
    }

    func expireAccessTokens() {
        state.withLock { s in for key in s.accessTokens.keys { s.accessTokens[key] = .distantPast } }
    }

    func removeAccess() {
        state.withLock { s in
            s.refreshTokens.removeAll()
            s.accessTokens.removeAll()
        }
    }

    // MARK: HTTP

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            var yes: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(connection) }.start()
        }
    }

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(),
                     headers: ["Content-Type": "application/json"])
        }

        static func error(_ status: Int, _ code: String, _ message: String) -> Response {
            .json(["error": ["code": code, "message": message]], status: status)
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var pending = Data()
        while true {
            guard let request = readRequest(connection, &pending) else { return }
            let response = handle(request)
            var head = "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\n"
            for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8)
            out.append(response.body)
            let sent = out.withUnsafeBytes { send(connection, $0.baseAddress, out.count, 0) }
            if sent != out.count { return }
        }
    }

    private func readRequest(_ connection: Int32, _ pending: inout Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while pending.range(of: separator) == nil {
            let n = recv(connection, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            pending.append(contentsOf: buffer[0..<n])
        }
        let end = pending.range(of: separator)!
        let head = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
        pending = Data(pending[end.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while pending.count < length {
            let n = recv(connection, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            pending.append(contentsOf: buffer[0..<n])
        }
        let body = Data(pending.prefix(length))
        pending = Data(pending.dropFirst(length))
        let target = first.count > 1 ? String(first[1]) : "/"
        let components = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first.first ?? ""), path: components?.path ?? "/", query: query,
                       headers: headers, body: body)
    }

    private func handle(_ request: Request) -> Response {
        if request.path == "/common/oauth2/v2.0/token" { return token(request) }
        let parts = request.path.split(separator: "/").map(String.init)
        // Addresses with their own authorisation.
        if let first = parts.first, ["download", "upload", "monitor"].contains(first), parts.count == 2 {
            if request.header("Authorization") != nil { state.withLock { $0.leakedTokens += 1 } }
            switch (first, request.method) {
            case ("download", "GET"): return download(parts[1], request)
            case ("upload", "PUT"): return uploadPiece(parts[1], request)
            case ("upload", "DELETE"):
                _ = state.withLock { $0.sessions.removeValue(forKey: parts[1]) }
                return Response(status: 204, body: Data())
            case ("monitor", "GET"): return monitor(parts[1])
            default: return .error(405, "invalidRequest", "No such call")
            }
        }
        let bearer = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let valid = state.withLock { s in s.accessTokens[bearer].map { $0 > Date() } }
        guard valid == true else {
            return .error(401, "InvalidAuthenticationToken", "Access token has expired or is not yet valid.")
        }
        let limited = state.withLock { s -> Bool in
            s.requests.append("\(request.method) \(request.path)")
            guard s.rateLimited > 0 else { return false }
            s.rateLimited -= 1
            return true
        }
        if limited {
            var response = Response.error(429, "activityLimitReached", "The request has been throttled")
            response.headers["Retry-After"] = "0"
            return response
        }
        guard parts.first == "v1.0" else { return .error(404, "invalidRequest", "No such call: \(request.path)") }
        let rest = Array(parts.dropFirst())
        let method = request.method
        if rest == ["me"], method == "GET" {
            return .json(["id": userID, "displayName": "Tester", "mail": NSNull(), "userPrincipalName": email])
        }
        let business = state.withLock { $0.business }
        if rest == ["me", "drive"], method == "GET" {
            return .json(["id": Self.myDrive, "driveType": business ? "business" : "personal"])
        }
        if rest == ["me", "drive", "root"], method == "GET" { return get(rootID) }
        if rest.count == 4, rest[0] == "drives", rest[2] == "root", rest[3] == "delta", method == "GET" {
            let drive = rest[1]
            return state.withLock { s -> Response in
                let now = s.items.filter { $0.value.drive == drive }
                    .mapValues { "\($0.name)|\($0.parent ?? "")|\($0.version)|\($0.deleted)" }
                var value: [[String: Any]] = []
                if let n = Int(request.query["token"] ?? ""), s.deltas.indices.contains(n) {
                    let then = s.deltas[n]
                    for id in Set(then.keys).union(now.keys) where then[id] != now[id] {
                        var entry: [String: Any] = ["id": id]
                        if let parent = s.items[id]?.parent { entry["parentReference"] = ["id": parent] }
                        if s.items[id]?.deleted != false { entry["deleted"] = ["state": "deleted"] }
                        value.append(entry)
                    }
                } else if request.query["token"] != "latest" {
                    return .error(410, "resyncRequired", "Resync required")
                }
                s.deltas.append(now)
                return .json(["value": value,
                              "@odata.deltaLink": "\(base)/v1.0/drives/\(drive)/root/delta?token=\(s.deltas.count - 1)"])
            }
        }
        // /drives/{d}/items/{id}[:/{name}:][/{action}]
        guard rest.count >= 4, rest[0] == "drives", rest[2] == "items" else {
            return .error(404, "invalidRequest", "No such call: \(request.path)")
        }
        let drive = rest[1]
        var id = rest[3]
        var name: String?
        var action = Array(rest.dropFirst(4))
        if id.hasSuffix(":") || (action.first?.hasSuffix(":") ?? false) || id.contains(":") {
            // "id5:" then the name and its closing ":".
            let joined = ([id] + action).joined(separator: "/")
            guard let match = joined.firstMatch(of: /^([^:]+):\/?([^\/]*):(?:\/(.*))?$/) else {
                return .error(400, "invalidRequest", "Bad path \(joined)")
            }
            id = String(match.1)
            name = String(match.2)
            action = match.3.map { $0.split(separator: "/").map(String.init) } ?? []
        }
        guard let folder = item(id), folder.drive == drive, !folder.deleted else {
            return .error(404, "itemNotFound", "Item not found")
        }
        if let name {
            switch (method, action) {
            case ("GET", []):
                guard let found = named(name, in: id) else { return .error(404, "itemNotFound", "Item not found") }
                return get(found.id)
            case ("PUT", ["content"]): return simpleUpload(name, in: folder, request)
            case ("POST", ["createUploadSession"]): return createSession(name, in: folder, request)
            default: return .error(400, "invalidRequest", "No such call")
            }
        }
        switch (method, action) {
        case ("GET", []): return get(id)
        case ("GET", ["children"]):
            if folder.vault { return .error(400, "invalidRequest", "ObjectHandle is Invalid") }
            return list(id, request)
        case ("GET", ["content"]):
            guard !folder.folder else { return .error(400, "invalidRequest", "Folders have no content") }
            return Response(status: 302, body: Data(), headers: ["Location": "\(other)/download/\(id)"])
        case ("PATCH", []): return update(id, request)
        case ("DELETE", []): return delete(id, permanent: false)
        case ("POST", ["permanentDelete"]):
            guard business else { return .error(400, "invalidRequest", "permanentDelete is not supported for this drive") }
            return delete(id, permanent: true)
        case ("POST", ["children"]): return makeFolder(in: folder, request)
        case ("POST", ["copy"]): return copy(id, request)
        default: return .error(400, "invalidRequest", "No such call: \(method) \(request.path)")
        }
    }

    // MARK: Tokens

    private func token(_ request: Request) -> Response {
        var form: [String: String] = [:]
        for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { form[kv[0]] = kv[1] }
        }
        guard form["client_id"] == Self.clientID, form["client_secret"] == nil else {
            return .json(["error": "invalid_client", "error_description": "AADSTS7000218: bad client"], status: 401)
        }
        return state.withLock { s in
            func issue() -> Response {
                let refresh = "refresh-\(UUID().uuidString)"
                let access = "access-\(UUID().uuidString)"
                s.refreshTokens.insert(refresh)
                s.accessTokens[access] = Date().addingTimeInterval(s.lifetime)
                return .json(["access_token": access, "refresh_token": refresh, "expires_in": Int(s.lifetime),
                              "scope": s.grantedScopes, "token_type": "Bearer"])
            }
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"], let saved = s.codes.removeValue(forKey: code),
                      let verifier = form["code_verifier"], saved.redirect == form["redirect_uri"],
                      OAuthPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == saved.challenge else {
                    return .json(["error": "invalid_grant", "error_description": "AADSTS70000: Bad code or verifier"], status: 400)
                }
                s.signIns += 1
                return issue()
            case "refresh_token":
                // Each refresh token works once: the answer brings the next one.
                guard let refresh = form["refresh_token"], s.refreshTokens.remove(refresh) != nil else {
                    return .json(["error": "invalid_grant", "error_description": "AADSTS70008: The refresh token has expired."], status: 400)
                }
                s.refreshes += 1
                return issue()
            default:
                return .json(["error": "unsupported_grant_type"], status: 400)
            }
        }
    }

    // MARK: Graph

    static func iso(_ date: Date) -> String { DriveDate.format(date) }

    private func json(_ item: Item, _ s: State) -> [String: Any] {
        var result: [String: Any] = [
            "id": item.id, "name": item.name,
            "createdDateTime": Self.iso(item.created), "lastModifiedDateTime": Self.iso(item.serverModified),
            "fileSystemInfo": ["createdDateTime": Self.iso(item.created), "lastModifiedDateTime": Self.iso(item.modified)],
            "eTag": "\"\(item.id),\(item.version)\"", "cTag": "\"c:\(item.id),\(item.version)\"",
            "parentReference": ["driveId": item.drive, "id": item.parent ?? ""],
            "webUrl": "https://onedrive.live.com/?id=\(item.id)",
        ]
        if let remote = item.remote, let target = s.items[remote.id] {
            result["remoteItem"] = ["id": target.id, "name": target.name, "folder": ["childCount": 0],
                                    "parentReference": ["driveId": target.drive],
                                    "webUrl": "https://onedrive.live.com/?id=\(target.id)"]
        } else if item.folder {
            result["folder"] = ["childCount": s.items.values.filter { $0.parent == item.id && !$0.deleted }.count]
            result["size"] = 0
        } else {
            var hash = QuickXorHash()
            hash.update(item.data)
            result["size"] = item.data.count
            result["file"] = ["mimeType": "application/octet-stream", "hashes": ["quickXorHash": hash.base64]]
        }
        return result
    }

    private func get(_ id: String) -> Response {
        state.withLock { s in
            guard let item = s.items[id], !item.deleted else { return .error(404, "itemNotFound", "Item not found") }
            return .json(json(item, s))
        }
    }

    /// The item of a name in a folder, without regard to case.
    private func named(_ name: String, in parent: String) -> Item? {
        state.withLock { s in
            s.items.values.first { $0.parent == parent && !$0.deleted && $0.name.lowercased() == name.lowercased() }
        }
    }

    private func list(_ id: String, _ request: Request) -> Response {
        let top = Int(request.query["$top"] ?? "200") ?? 200
        let skip = Int(request.query["$skiptoken"] ?? "0") ?? 0
        return state.withLock { s in
            let all = s.items.values.filter { $0.parent == id && !$0.deleted }
                .sorted { $0.id.count != $1.id.count ? $0.id.count < $1.id.count : $0.id < $1.id }
            // Pages of at most 3, so the tests see several.
            let size = min(top, 3)
            let page = all.dropFirst(skip).prefix(size)
            var answer: [String: Any] = ["value": page.map { json($0, s) }]
            if skip + size < all.count, top > 1 {
                let drive = s.items[id]?.drive ?? ""
                answer["@odata.nextLink"] = "\(base)/v1.0/drives/\(drive)/items/\(id)/children?$top=\(top)&$skiptoken=\(skip + size)"
            }
            return .json(answer)
        }
    }

    private func download(_ id: String, _ request: Request) -> Response {
        let item = state.withLock { $0.items[id] }
        guard let item, !item.deleted else { return .error(404, "itemNotFound", "Item not found") }
        if let range = request.header("Range"), range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            if start >= item.data.count { return Response(status: 416, body: Data()) }
            return Response(status: 206, body: Data(item.data[start...]),
                            headers: ["Content-Range": "bytes \(start)-\(item.data.count - 1)/\(item.data.count)"])
        }
        return Response(status: 200, body: item.data)
    }

    private func conflict(_ name: String, in parent: String, except: String? = nil) -> Bool {
        named(name, in: parent).map { $0.id != except } ?? false
    }

    private func update(_ id: String, _ request: Request) -> Response {
        let body = request.json
        return state.withLock { s in
            guard var item = s.items[id], !item.deleted else { return .error(404, "itemNotFound", "Item not found") }
            let parent = ((body["parentReference"] as? [String: Any])?["id"] as? String) ?? item.parent ?? ""
            let name = body["name"] as? String ?? item.name
            if s.items.values.contains(where: { $0.parent == parent && !$0.deleted && $0.id != id && $0.name.lowercased() == name.lowercased() }) {
                return .error(409, "nameAlreadyExists", "An item with the same name already exists")
            }
            if parent != item.parent {
                guard s.items[parent]?.drive == item.drive else { return .error(400, "invalidRequest", "Moves stay in one drive") }
                item.parent = parent
            }
            item.name = name
            if let info = body["fileSystemInfo"] as? [String: Any],
               let date = (info["lastModifiedDateTime"] as? String).flatMap(DriveDate.parse) {
                item.modified = date
            }
            s.items[id] = item
            return .json(json(item, s))
        }
    }

    private func delete(_ id: String, permanent: Bool) -> Response {
        state.withLock { s in
            guard s.items[id] != nil, s.items[id]?.deleted == false else { return .error(404, "itemNotFound", "Item not found") }
            var gone = [id]
            if permanent { s.permanentDeletes += 1 }
            while let next = gone.popLast() {
                if permanent { s.items[next] = nil } else { s.items[next]?.deleted = true }
                gone += s.items.values.filter { $0.parent == next && !$0.deleted }.map(\.id)
            }
            return Response(status: 204, body: Data())
        }
    }

    private func makeFolder(in parent: Item, _ request: Request) -> Response {
        let body = request.json
        guard let name = body["name"] as? String, body["folder"] != nil else { return .error(400, "invalidRequest", "Bad folder") }
        if conflict(name, in: parent.id) { return .error(409, "nameAlreadyExists", "An item with the same name already exists") }
        let id = folder(name, in: parent.id)
        var response = get(id)
        response.status = 201
        return response
    }

    private func copy(_ id: String, _ request: Request) -> Response {
        let body = request.json
        guard let source = item(id), !source.folder else { return .error(400, "invalidRequest", "Bad copy") }
        let reference = body["parentReference"] as? [String: Any]
        let parent = reference?["id"] as? String ?? source.parent ?? rootID
        let name = body["name"] as? String ?? source.name
        if conflict(name, in: parent) { return .error(409, "nameAlreadyExists", "An item with the same name already exists") }
        let copied = put(name, in: parent, source.data, modified: source.modified)
        let monitor = UUID().uuidString
        state.withLock { $0.monitors[monitor] = (copied, 0) }
        return Response(status: 202, body: Data(), headers: ["Location": "\(other)/monitor/\(monitor)"])
    }

    private func monitor(_ id: String) -> Response {
        state.withLock { s in
            guard var entry = s.monitors[id] else { return .error(404, "itemNotFound", "No such copy") }
            entry.asked += 1
            s.monitors[id] = entry
            if entry.asked < 2 { return .json(["status": "inProgress", "percentageComplete": 50.0], status: 202) }
            return .json(["status": "completed", "resourceId": entry.id])
        }
    }

    // MARK: Uploads

    private func store(_ name: String, in parent: Item, _ data: Data, modified: Date?) -> Response {
        if conflict(name, in: parent.id) { return .error(409, "nameAlreadyExists", "An item with the same name already exists") }
        let id = put(name, in: parent.id, data, modified: modified)
        var response = get(id)
        response.status = 201
        return response
    }

    private func simpleUpload(_ name: String, in parent: Item, _ request: Request) -> Response {
        guard request.query["@microsoft.graph.conflictBehavior"] == "fail" else {
            return .error(400, "invalidRequest", "Basil always asks to fail on conflicts")
        }
        return store(name, in: parent, request.body, modified: nil)
    }

    private func createSession(_ name: String, in parent: Item, _ request: Request) -> Response {
        let item = request.json["item"] as? [String: Any] ?? [:]
        guard item["@microsoft.graph.conflictBehavior"] as? String == "fail" else {
            return .error(400, "invalidRequest", "Basil always asks to fail on conflicts")
        }
        if conflict(name, in: parent.id) { return .error(409, "nameAlreadyExists", "An item with the same name already exists") }
        let modified = ((item["fileSystemInfo"] as? [String: Any])?["lastModifiedDateTime"] as? String).flatMap(DriveDate.parse)
        let id = UUID().uuidString
        state.withLock { $0.sessions[id] = Session(drive: parent.drive, parent: parent.id, name: name, modified: modified) }
        return .json(["uploadUrl": "\(other)/upload/\(id)", "expirationDateTime": Self.iso(Date() + 3600)])
    }

    private func uploadPiece(_ id: String, _ request: Request) -> Response {
        guard let range = request.header("Content-Range"),
              let match = range.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/),
              let start = Int(match.1), let end = Int(match.2), let total = Int(match.3) else {
            return .error(400, "invalidRange", "Content-Range must name the piece and the total size")
        }
        enum Step { case answer(Response), finish(Session) }
        let step = state.withLock { s -> Step in
            guard var session = s.sessions[id] else { return .answer(.error(404, "itemNotFound", "No such upload")) }
            guard start == session.data.count, end - start + 1 == request.body.count,
                  session.total == nil || session.total == total else {
                return .answer(.error(416, "invalidRange", "Range \(range) does not follow \(session.data.count) bytes"))
            }
            session.data.append(request.body)
            session.total = total
            s.chunks += 1
            if session.data.count >= total {
                s.sessions[id] = nil
                return .finish(session)
            }
            // Every piece but the last is a multiple of 320 KiB.
            guard request.body.count % (320 * 1024) == 0 else {
                return .answer(.error(400, "invalidRange", "Not a multiple of 320 KiB"))
            }
            s.sessions[id] = session
            return .answer(.json(["nextExpectedRanges": ["\(session.data.count)-"]], status: 202))
        }
        switch step {
        case .answer(let response): return response
        case .finish(let session):
            guard let parent = item(session.parent) else { return .error(404, "itemNotFound", "Folder gone") }
            return store(session.name, in: parent, session.data, modified: session.modified)
        }
    }
}

/// The UI's side for the OneDrive tests: plays the browser against the fake.
final class MicrosoftBrowserPrompts: RemotePrompts, @unchecked Sendable {
    let drive: FakeOneDrive
    let giveUp: Bool
    let signIns = Mutex<[BrowserSignIn]>([])
    let returnPages = Mutex<[String]>([])

    init(_ drive: FakeOneDrive, giveUp: Bool = false) {
        self.drive = drive
        self.giveUp = giveUp
    }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer { .cancel }
    func secret(_ request: SecretRequest) async -> SecretAnswer? { nil }

    func browserSignIn(_ request: BrowserSignIn) async {
        signIns.withLock { $0.append(request) }
        if giveUp { return }
        if let back = drive.authorize(request.url) {
            Task {
                try? await Task.sleep(for: .milliseconds(20))
                if let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: back) {
                    returnPages.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
                }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
