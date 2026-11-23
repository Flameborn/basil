import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization
@testable import BasilRemote

/// A small Google Drive for the tests: an HTTP server on 127.0.0.1 that answers the token
/// endpoint and the Drive API calls Basil makes (about, listing with the query forms Basil
/// sends, shared drives, metadata, folders, updates with parent changes, copies, deletes,
/// ranged downloads, exports, multipart and resumable uploads), with items kept in memory by ID.
/// It checks PKCE, the client secret, refresh tokens, expired access tokens and the byte ranges
/// of resumable uploads. The browser part of signing in is `authorize(_:)`.
final class FakeGoogleDrive: @unchecked Sendable {
    static let client = GoogleClient(id: "test-client.apps.googleusercontent.com", secret: "test-secret")
    static let googleDoc = "application/vnd.google-apps.document"

    struct Item {
        var id: String
        var name: String
        var mimeType: String
        var parents: [String]
        var data = Data()
        var created: Date
        var modified: Date
        var version = 1
        var trashed = false
        var driveId: String?
        var target: String?
        var targetMime: String?
    }

    struct Upload {
        /// The JSON sent when the upload started.
        var metadata: Data
        var data = Data()
    }

    struct State {
        var items: [String: Item] = [:]
        var drives: [(id: String, name: String)] = []
        var sharedWithMe: Set<String> = []
        var codes: [String: (challenge: String, redirect: String)] = [:]
        var refreshTokens: Set<String> = []
        var accessTokens: [String: Date] = [:]
        var uploads: [String: Upload] = [:]
        var counter = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var lifetime: TimeInterval = 3600
        /// Scopes the next sign-in grants.
        var grantedScopes = GoogleScopes.drive
        var signIns = 0
        var refreshes = 0
        var revokes = 0
        var exports = 0
        var chunks = 0
        /// Answer this many API calls with Drive's rate-limit error first.
        var rateLimited = 0
        var requests: [String] = []
    }

    let state = Mutex(State())
    let rootID = "root-folder-id"
    let permissionID = "01234567890123456789"
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
            s.items[rootID] = Item(id: rootID, name: "My Drive", mimeType: DriveFile.folderType, parents: [],
                                   created: s.clock, modified: s.clock)
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit { close(listener) }

    var base: String { "http://127.0.0.1:\(port)" }
    var hosts: GoogleHosts { GoogleHosts(accounts: base, oauth: base, api: base) }

    // MARK: Items

    private func newID(_ s: inout State) -> String {
        s.counter += 1
        return "id\(s.counter)"
    }

    @discardableResult
    func put(_ name: String, in parent: String? = nil, _ data: Data, mime: String = "application/octet-stream",
             created: Date? = nil, modified: Date? = nil) -> String {
        state.withLock { s in
            s.clock += 1
            let id = newID(&s)
            let parent = parent ?? rootID
            s.items[id] = Item(id: id, name: name, mimeType: mime, parents: [parent], data: data,
                               created: created ?? s.clock, modified: modified ?? s.clock,
                               driveId: s.items[parent]?.driveId ?? s.drives.first { $0.id == parent }?.id)
            return id
        }
    }

    /// Changes a file's content (a new version).
    func change(_ id: String, _ data: Data, modified: Date? = nil) {
        state.withLock { s in
            s.clock += 1
            s.items[id]?.data = data
            s.items[id]?.version += 1
            s.items[id]?.modified = modified ?? s.clock
        }
    }

    @discardableResult
    func folder(_ name: String, in parent: String? = nil) -> String {
        put(name, in: parent, Data(), mime: DriveFile.folderType)
    }

    @discardableResult
    func shortcut(_ name: String, in parent: String? = nil, to target: String) -> String {
        let id = put(name, in: parent, Data(), mime: DriveFile.shortcutType)
        state.withLock { s in
            s.items[id]?.target = target
            let mime = s.items[target]?.mimeType
            s.items[id]?.targetMime = mime
        }
        return id
    }

    @discardableResult
    func drive(_ name: String) -> String {
        state.withLock { s in
            let id = "drive\(s.drives.count + 1)"
            s.drives.append((id, name))
            return id
        }
    }

    func share(_ id: String) { _ = state.withLock { $0.sharedWithMe.insert(id) } }

    func item(_ id: String) -> Item? { state.withLock { $0.items[id] } }

    /// The untrashed items in a folder.
    func children(_ parent: String? = nil) -> [Item] {
        state.withLock { s in
            s.items.values.filter { $0.parents.contains(parent ?? rootID) && !$0.trashed }.sorted { $0.name < $1.name }
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
        guard url.path == "/o/oauth2/v2/auth", value("client_id") == Self.client.id, value("response_type") == "code",
              value("code_challenge_method") == "S256", value("access_type") == "offline",
              value("scope") == GoogleScopes.drive,
              let challenge = value("code_challenge"), let redirect = value("redirect_uri"),
              let state = value("state") else { return nil }
        let code = "code-\(UUID().uuidString)"
        self.state.withLock { $0.codes[code] = (challenge, redirect) }
        return URL(string: "\(redirect)?state=\(state)&code=\(code)&scope=\(GoogleAuth.formEncode(self.state.withLock { $0.grantedScopes }))")
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

        static func error(_ status: Int, _ reason: String, _ message: String) -> Response {
            .json(["error": ["code": status, "message": message, "errors": [["reason": reason, "message": message]]]], status: status)
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
        if request.path == "/token" { return token(request) }
        if request.path == "/revoke" { return revoke(request) }
        let bearer = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let valid = state.withLock { s in s.accessTokens[bearer].map { $0 > Date() } }
        guard valid == true else {
            return .error(401, "authError", "Request had invalid authentication credentials.")
        }
        let limited = state.withLock { s -> Bool in
            s.requests.append("\(request.method) \(request.path)")
            guard s.rateLimited > 0 else { return false }
            s.rateLimited -= 1
            return true
        }
        if limited { return .error(403, "userRateLimitExceeded", "User rate limit exceeded.") }
        let parts = request.path.split(separator: "/").map(String.init)
        let method = request.method
        let api = parts.count >= 3 && parts[0] == "drive" && parts[1] == "v3"
        let rest = api ? Array(parts.dropFirst(2)) : []
        if api, rest == ["about"], method == "GET" { return about() }
        if api, rest == ["drives"], method == "GET" { return drives(request) }
        if api, rest == ["files"] {
            if method == "GET" { return list(request) }
            if method == "POST" { return create(request) }
        }
        if api, rest.count == 2, rest[0] == "files" {
            let id = rest[1]
            switch method {
            case "GET": return request.query["alt"] == "media" ? media(id, request) : get(id)
            case "PATCH": return update(id, request)
            case "DELETE": return delete(id)
            default: break
            }
        }
        if api, rest.count == 3, rest[0] == "files", rest[2] == "copy", method == "POST" { return copy(rest[1], request) }
        if api, rest.count == 3, rest[0] == "files", rest[2] == "export", method == "GET" { return export(rest[1], request) }
        if parts == ["upload", "drive", "v3", "files"], method == "POST" {
            return request.query["uploadType"] == "resumable" ? startUpload(request) : multipart(request)
        }
        if parts.count == 3, parts[0] == "upload", parts[1] == "session" {
            if method == "PUT" { return uploadChunk(parts[2], request) }
            if method == "DELETE" {
                _ = state.withLock { $0.uploads.removeValue(forKey: parts[2]) }
                return Response(status: 499, body: Data())
            }
        }
        return .error(404, "notFound", "No such call: \(method) \(request.path)")
    }

    // MARK: Tokens

    private func token(_ request: Request) -> Response {
        var form: [String: String] = [:]
        for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { form[kv[0]] = kv[1] }
        }
        guard form["client_id"] == Self.client.id, form["client_secret"] == Self.client.secret else {
            return .json(["error": "invalid_client"], status: 401)
        }
        return state.withLock { s in
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"], let saved = s.codes.removeValue(forKey: code),
                      let verifier = form["code_verifier"], saved.redirect == form["redirect_uri"],
                      OAuthPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == saved.challenge else {
                    return .json(["error": "invalid_grant", "error_description": "Bad code or verifier"], status: 400)
                }
                s.signIns += 1
                let refresh = "refresh-\(UUID().uuidString)"
                let access = "access-\(UUID().uuidString)"
                s.refreshTokens.insert(refresh)
                s.accessTokens[access] = Date().addingTimeInterval(s.lifetime)
                return .json(["access_token": access, "refresh_token": refresh, "expires_in": s.lifetime,
                              "scope": s.grantedScopes, "token_type": "Bearer"])
            case "refresh_token":
                guard let refresh = form["refresh_token"], s.refreshTokens.contains(refresh) else {
                    return .json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."], status: 400)
                }
                s.refreshes += 1
                let access = "access-\(UUID().uuidString)"
                s.accessTokens[access] = Date().addingTimeInterval(s.lifetime)
                return .json(["access_token": access, "expires_in": s.lifetime, "token_type": "Bearer"])
            default:
                return .json(["error": "unsupported_grant_type"], status: 400)
            }
        }
    }

    private func revoke(_ request: Request) -> Response {
        let text = String(decoding: request.body, as: UTF8.self)
        let token = text.hasPrefix("token=") ? String(text.dropFirst(6)).removingPercentEncoding ?? "" : ""
        return state.withLock { s in
            guard s.refreshTokens.remove(token) != nil else { return .json(["error": "invalid_token"], status: 400) }
            s.revokes += 1
            return .json([:])
        }
    }

    // MARK: Drive

    private func about() -> Response {
        .json(["user": ["displayName": "Tester", "emailAddress": email, "permissionId": permissionID]])
    }

    private func drives(_ request: Request) -> Response {
        let list = state.withLock { $0.drives }
        return .json(["drives": list.map { ["id": $0.id, "name": $0.name] }])
    }

    static func iso(_ date: Date) -> String { DriveDate.format(date) }

    private func json(_ item: Item) -> [String: Any] {
        var result: [String: Any] = [
            "id": item.id, "name": item.name, "mimeType": item.mimeType, "parents": item.parents,
            "createdTime": Self.iso(item.created), "modifiedTime": Self.iso(item.modified),
            "version": String(item.version), "trashed": item.trashed,
            "webViewLink": "https://drive.google.com/file/d/\(item.id)/view",
        ]
        if item.mimeType != DriveFile.folderType, !DriveFile.isGoogleType(item.mimeType), item.mimeType != DriveFile.shortcutType {
            result["size"] = String(item.data.count)
            result["md5Checksum"] = Insecure.MD5.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
        }
        if let drive = item.driveId { result["driveId"] = drive }
        if let target = item.target {
            result["shortcutDetails"] = ["targetId": target, "targetMimeType": item.targetMime ?? ""]
        }
        return result
    }

    private func resolve(_ id: String) -> String { id == "root" ? rootID : id }

    private func get(_ id: String) -> Response {
        state.withLock { s in
            guard let item = s.items[resolve(id)] else { return .error(404, "notFound", "File not found: \(id).") }
            return .json(json(item))
        }
    }

    /// The query forms Basil sends.
    private func list(_ request: Request) -> Response {
        let q = request.query["q"] ?? ""
        let pageSize = Int(request.query["pageSize"] ?? "100") ?? 100
        let offset = Int(request.query["pageToken"] ?? "0") ?? 0
        func unquote(_ text: Substring) -> String {
            text.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\\", with: "\\")
        }
        let found: [Item] = state.withLock { s in
            var items = Array(s.items.values.filter { !$0.trashed })
            if q.hasPrefix("sharedWithMe = true") {
                items = items.filter { s.sharedWithMe.contains($0.id) }
            } else if let match = q.firstMatch(of: /^'((?:[^'\\]|\\.)*)' in parents and (?:name = '((?:[^'\\]|\\.)*)' and )?trashed = false$/) {
                let parent = unquote(match.1)
                items = items.filter { $0.parents.contains(parent) }
                if let name = match.2 { items = items.filter { $0.name == unquote(name) } }
            } else {
                items = []
            }
            return items.sorted { $0.id.count != $1.id.count ? $0.id.count < $1.id.count : $0.id < $1.id }
        }
        if !q.hasPrefix("sharedWithMe = true"), !q.contains(" in parents and ") {
            return .error(400, "invalid", "Invalid Value: \(q)")
        }
        let page = Array(found.dropFirst(offset).prefix(pageSize))
        var answer: [String: Any] = ["files": page.map(json)]
        if offset + pageSize < found.count { answer["nextPageToken"] = String(offset + pageSize) }
        return .json(answer)
    }

    private func media(_ id: String, _ request: Request) -> Response {
        let item = state.withLock { $0.items[id] }
        guard let item, !item.trashed else { return .error(404, "notFound", "File not found: \(id).") }
        if DriveFile.isGoogleType(item.mimeType) {
            return .error(403, "fileNotDownloadable", "Only files with binary content can be downloaded. Use Export with Docs Editors files.")
        }
        if let range = request.header("Range"), range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            if start >= item.data.count { return Response(status: 416, body: Data()) }
            return Response(status: 206, body: Data(item.data[start...]),
                            headers: ["Content-Range": "bytes \(start)-\(item.data.count - 1)/\(item.data.count)"])
        }
        return Response(status: 200, body: item.data)
    }

    /// The export of a Google document: its type and data, so tests can check them.
    static func exported(_ data: Data, as mime: String) -> Data { Data("EXPORT \(mime)\n".utf8) + data }

    private func export(_ id: String, _ request: Request) -> Response {
        let item = state.withLock { s -> Item? in
            s.exports += 1
            return s.items[id]
        }
        guard let item else { return .error(404, "notFound", "File not found: \(id).") }
        guard let mime = request.query["mimeType"], DriveFile.isGoogleType(item.mimeType) else {
            return .error(400, "badRequest", "Export only supports Docs Editors files.")
        }
        return Response(status: 200, body: Self.exported(item.data, as: mime))
    }

    private func create(_ request: Request) -> Response {
        let body = request.json
        guard let name = body["name"] as? String, let parent = (body["parents"] as? [String])?.first else {
            return .error(400, "required", "Required parameter missing")
        }
        let mime = body["mimeType"] as? String ?? "application/octet-stream"
        let id = put(name, in: resolve(parent), Data(), mime: mime)
        return get(id)
    }

    private func update(_ id: String, _ request: Request) -> Response {
        let body = request.json
        return state.withLock { s in
            guard var item = s.items[id] else { return .error(404, "notFound", "File not found: \(id).") }
            if let name = body["name"] as? String { item.name = name; item.version += 1 }
            if let trashed = body["trashed"] as? Bool { item.trashed = trashed; item.version += 1 }
            if let modified = (body["modifiedTime"] as? String).flatMap(DriveDate.parse) { item.modified = modified }
            if let add = request.query["addParents"] {
                if let remove = request.query["removeParents"] { item.parents.removeAll { $0 == remove } }
                item.parents.append(add)
            }
            s.items[id] = item
            return .json(json(item))
        }
    }

    private func delete(_ id: String) -> Response {
        state.withLock { s in
            guard s.items[id] != nil else { return .error(404, "notFound", "File not found: \(id).") }
            var gone = [id]
            while let next = gone.popLast() {
                s.items[next] = nil
                gone += s.items.values.filter { $0.parents.contains(next) }.map(\.id)
            }
            return Response(status: 204, body: Data())
        }
    }

    private func copy(_ id: String, _ request: Request) -> Response {
        let body = request.json
        guard let source = item(id) else { return .error(404, "notFound", "File not found: \(id).") }
        guard source.mimeType != DriveFile.folderType else { return .error(403, "cannotCopyFile", "Folders cannot be copied") }
        let parent = (body["parents"] as? [String])?.first ?? source.parents.first ?? rootID
        let copied = put(body["name"] as? String ?? "Copy of \(source.name)", in: parent, source.data, mime: source.mimeType)
        return get(copied)
    }

    // MARK: Uploads

    private func finishUpload(_ metadata: [String: Any], _ data: Data) -> Response {
        guard let name = metadata["name"] as? String, let parent = (metadata["parents"] as? [String])?.first else {
            return .error(400, "required", "Required parameter missing")
        }
        let modified = (metadata["modifiedTime"] as? String).flatMap(DriveDate.parse)
        let id = put(name, in: parent, data, modified: modified)
        return .json(["id": id, "name": name, "kind": "drive#file"])
    }

    private func multipart(_ request: Request) -> Response {
        guard let type = request.header("Content-Type"), let range = type.range(of: "boundary=") else {
            return .error(400, "badContent", "No boundary")
        }
        let boundary = Data(("--" + type[range.upperBound...]).utf8)
        var parts: [Data] = []
        var rest = request.body[...]
        while let start = rest.range(of: boundary) {
            rest = rest[start.upperBound...]
            guard let end = rest.range(of: boundary) else { break }
            parts.append(Data(rest[rest.startIndex..<end.lowerBound]))
        }
        func content(_ part: Data) -> Data {
            guard let split = part.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
            return Data(part[split.upperBound...].dropLast(2))
        }
        guard parts.count == 2,
              let metadata = (try? JSONSerialization.jsonObject(with: content(parts[0]))) as? [String: Any] else {
            return .error(400, "badContent", "Expected two parts")
        }
        return finishUpload(metadata, content(parts[1]))
    }

    private func startUpload(_ request: Request) -> Response {
        let id = UUID().uuidString
        let metadata = request.body
        state.withLock { $0.uploads[id] = Upload(metadata: metadata) }
        return Response(status: 200, body: Data(), headers: ["Location": "\(base)/upload/session/\(id)"])
    }

    private func uploadChunk(_ id: String, _ request: Request) -> Response {
        guard let range = request.header("Content-Range"), range.hasPrefix("bytes ") else {
            return .error(400, "badRange", "Content-Range missing")
        }
        let spec = range.dropFirst(6).split(separator: "/")
        let total = spec.count == 2 ? Int(spec[1]) : nil
        enum Step { case answer(Response), finish(Upload) }
        let step = state.withLock { s -> Step in
            guard var upload = s.uploads[id] else { return .answer(.error(404, "notFound", "No such upload")) }
            if spec.first != "*" {
                let bounds = spec[0].split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] == upload.data.count, bounds[1] - bounds[0] + 1 == request.body.count else {
                    return .answer(.error(400, "badRange", "Range \(range) does not follow \(upload.data.count) bytes"))
                }
                // Every piece but the last is a multiple of 256 KB.
                if total == nil, request.body.count % (256 << 10) != 0 {
                    return .answer(.error(400, "badRange", "Not a multiple of 256 KB"))
                }
                upload.data.append(request.body)
                s.chunks += 1
            }
            if let total {
                guard total == upload.data.count else { return .answer(.error(400, "badRange", "Size \(total) does not match")) }
                s.uploads[id] = nil
                return .finish(upload)
            }
            s.uploads[id] = upload
            return .answer(Response(status: 308, body: Data(), headers: ["Range": "bytes=0-\(upload.data.count - 1)"]))
        }
        switch step {
        case .answer(let response): return response
        case .finish(let upload):
            let metadata = (try? JSONSerialization.jsonObject(with: upload.metadata)) as? [String: Any] ?? [:]
            return finishUpload(metadata, upload.data)
        }
    }
}

/// The UI's side for the Google tests: plays the browser against the fake.
final class GoogleBrowserPrompts: RemotePrompts, @unchecked Sendable {
    let drive: FakeGoogleDrive
    let giveUp: Bool
    let signIns = Mutex<[BrowserSignIn]>([])
    let returnPages = Mutex<[String]>([])

    init(_ drive: FakeGoogleDrive, giveUp: Bool = false) {
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
