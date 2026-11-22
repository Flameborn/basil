import BasilCore
import BasilVFS
import CryptoKit
import Darwin
import Foundation
import Synchronization
@testable import BasilRemote

/// A small Dropbox for the tests: an HTTP server on 127.0.0.1 that answers the API calls Basil
/// makes (token endpoint, account, listing, metadata, folders, delete, move, copy, uploads and
/// upload sessions, ranged downloads by revision), with files kept in memory. It checks what
/// the real one checks where it matters: PKCE, refresh tokens, expired access tokens, content
/// hashes and upload offsets. The browser part of signing in is `authorize(_:)`.
final class FakeDropbox: @unchecked Sendable {
    static let appKey = "testappkey"

    struct Node {
        var display: String
        var folder: Bool
        var data = Data()
        var rev = ""
        var id: String
        var clientModified = Date(timeIntervalSince1970: 1_700_000_000)
        var serverModified = Date(timeIntervalSince1970: 1_700_000_000)
        var name: String { (display as NSString).lastPathComponent }
    }

    struct Token {
        var refresh: String
        var expires: Date
    }

    struct State {
        var nodes: [String: Node] = [:]
        /// Every revision's data, so a download pinned to a revision works after a change.
        var revisions: [String: Data] = [:]
        var codes: [String: (challenge: String, redirect: String)] = [:]
        var refreshTokens: Set<String> = []
        var accessTokens: [String: Token] = [:]
        var sessions: [String: Data] = [:]
        var counter = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        /// How long new access tokens last.
        var lifetime: TimeInterval = 14400
        var refreshes = 0
        var revokes = 0
        var downloads = 0
        var uploadedParts = 0
        /// Shared links by lower-cased path.
        var links: [String: String] = [:]
        /// Answer "shared_link_already_exists" without the link's metadata (Dropbox does both).
        var existingLinkWithoutMetadata = false
        /// Scopes the next sign-in grants.
        var grantedScopes = DropboxScopes.all
        var signIns = 0
    }

    let state = Mutex(State())
    let accountID = "dbid:AAAfakeaccount"
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
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit { close(listener) }

    var hosts: DropboxHosts {
        let base = "http://127.0.0.1:\(port)"
        return DropboxHosts(web: base, api: base, content: base)
    }

    // MARK: Files

    func put(_ path: String, _ data: Data, modified: Date? = nil) {
        state.withLock { s in
            s.counter += 1
            s.clock += 1
            let lower = path.lowercased()
            var node = s.nodes[lower] ?? Node(display: path, folder: false, id: "id:\(s.counter)")
            node.data = data
            node.rev = String(format: "%012x", 0x1000 + s.counter)
            node.serverModified = s.clock
            if let modified { node.clientModified = modified }
            s.revisions[node.rev] = data
            s.nodes[lower] = node
            makeParents(lower, display: path, &s)
        }
    }

    func makeFolder(_ path: String) {
        state.withLock { s in
            s.counter += 1
            s.nodes[path.lowercased()] = Node(display: path, folder: true, id: "id:\(s.counter)")
            makeParents(path.lowercased(), display: path, &s)
        }
    }

    func data(_ path: String) -> Data? { state.withLock { $0.nodes[path.lowercased()]?.data } }
    func node(_ path: String) -> Node? { state.withLock { $0.nodes[path.lowercased()] } }
    func names(in folder: String) -> [String] {
        state.withLock { s in s.nodes.values.filter { parent(of: $0.display.lowercased()) == folder.lowercased() }.map(\.name).sorted() }
    }

    private func makeParents(_ lower: String, display: String, _ s: inout State) {
        var parentLower = parent(of: lower)
        var parentDisplay = (display as NSString).deletingLastPathComponent
        while parentLower != "", s.nodes[parentLower] == nil {
            s.counter += 1
            s.nodes[parentLower] = Node(display: parentDisplay, folder: true, id: "id:\(s.counter)")
            parentLower = parent(of: parentLower)
            parentDisplay = (parentDisplay as NSString).deletingLastPathComponent
        }
    }

    private func parent(of lower: String) -> String {
        let p = (lower as NSString).deletingLastPathComponent
        return p == "/" ? "" : p
    }

    // MARK: Signing in

    /// What the browser does: checks the authorization request and returns the redirect back to
    /// the app with a code.
    func authorize(_ url: URL) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("client_id") == Self.appKey, value("response_type") == "code",
              value("code_challenge_method") == "S256", value("token_access_type") == "offline",
              let challenge = value("code_challenge"), let redirect = value("redirect_uri"),
              let state = value("state") else { return nil }
        let code = "code-\(UUID().uuidString)"
        self.state.withLock { $0.codes[code] = (challenge, redirect) }
        return URL(string: "\(redirect)?code=\(code)&state=\(state)")
    }

    /// Ends every access token now (the next call must refresh).
    func expireAccessTokens() {
        state.withLock { s in for key in s.accessTokens.keys { s.accessTokens[key]?.expires = .distantPast } }
    }

    /// Removes access on the Dropbox side ("Connected apps").
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
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(),
                     headers: ["Content-Type": "application/json"])
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
        return Request(method: String(first.first ?? ""), path: String(target.split(separator: "?").first ?? ""),
                       headers: headers, body: body)
    }

    private func handle(_ request: Request) -> Response {
        if request.path == "/oauth2/token" { return token(request) }
        // Every /2 call needs a valid access token.
        let bearer = request.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let valid = state.withLock { s in s.accessTokens[bearer].map { $0.expires > Date() } }
        guard valid == true else {
            let tag = valid == false ? "expired_access_token" : "invalid_access_token"
            return .json(["error_summary": "\(tag)/", "error": [".tag": tag]], status: 401)
        }
        let argument: [String: Any]
        if let header = request.header("Dropbox-API-Arg") {
            argument = (try? JSONSerialization.jsonObject(with: Data(header.utf8))) as? [String: Any] ?? [:]
        } else {
            argument = (try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        }
        switch request.path {
        case "/2/auth/token/revoke":
            state.withLock { s in
                if let token = s.accessTokens.removeValue(forKey: bearer) { s.refreshTokens.remove(token.refresh) }
                s.revokes += 1
            }
            return Response(status: 200, body: Data("null".utf8), headers: ["Content-Type": "application/json"])
        case "/2/users/get_current_account":
            return .json(account())
        case "/2/files/list_folder": return listFolder(argument)
        case "/2/files/list_folder/continue": return listContinue(argument)
        case "/2/files/get_metadata": return getMetadata(argument)
        case "/2/files/create_folder_v2": return createFolder(argument)
        case "/2/files/delete_v2": return delete(argument)
        case "/2/files/move_v2": return relocate(argument, move: true)
        case "/2/files/copy_v2": return relocate(argument, move: false)
        case "/2/files/upload": return upload(argument, request.body)
        case "/2/files/upload_session/start": return sessionStart(argument, request.body)
        case "/2/files/upload_session/append_v2": return sessionAppend(argument, request.body)
        case "/2/files/upload_session/finish": return sessionFinish(argument, request.body)
        case "/2/files/download": return download(argument, range: request.header("Range"))
        case "/2/sharing/create_shared_link_with_settings": return createLink(argument)
        case "/2/sharing/list_shared_links": return listLinks(argument)
        default: return Response(status: 404, body: Data("no route \(request.path)".utf8))
        }
    }

    // MARK: Routes

    private func token(_ request: Request) -> Response {
        var form: [String: String] = [:]
        for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { form[parts[0]] = parts[1] }
        }
        guard form["client_id"] == Self.appKey else {
            return .json(["error": "invalid_client", "error_description": "unknown app"], status: 400)
        }
        return state.withLock { s -> Response in
            let access = "access-\(UUID().uuidString)"
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"], let issued = s.codes.removeValue(forKey: code),
                      issued.redirect == form["redirect_uri"], let verifier = form["code_verifier"],
                      DropboxPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == issued.challenge else {
                    return .json(["error": "invalid_grant", "error_description": "bad code or verifier"], status: 400)
                }
                let refresh = "refresh-\(UUID().uuidString)"
                s.signIns += 1
                s.refreshTokens.insert(refresh)
                s.accessTokens[access] = Token(refresh: refresh, expires: Date().addingTimeInterval(s.lifetime))
                return .json(["access_token": access, "token_type": "bearer", "expires_in": s.lifetime,
                              "refresh_token": refresh, "uid": "12345", "account_id": accountID,
                              "scope": s.grantedScopes.joined(separator: " ")])
            case "refresh_token":
                guard let refresh = form["refresh_token"], s.refreshTokens.contains(refresh) else {
                    return .json(["error": "invalid_grant", "error_description": "refresh token is invalid or revoked"], status: 400)
                }
                s.refreshes += 1
                s.accessTokens[access] = Token(refresh: refresh, expires: Date().addingTimeInterval(s.lifetime))
                return .json(["access_token": access, "token_type": "bearer", "expires_in": s.lifetime])
            default:
                return .json(["error": "unsupported_grant_type"], status: 400)
            }
        }
    }

    private func account() -> [String: Any] {
        ["account_id": accountID,
         "name": ["given_name": "Test", "surname": "User", "familiar_name": "Test", "display_name": "Test User",
                  "abbreviated_name": "TU"],
         "email": email, "email_verified": true, "disabled": false, "locale": "en",
         "referral_link": "https://db.tt/x", "is_paired": false, "account_type": [".tag": "basic"],
         "root_info": [".tag": "user", "root_namespace_id": "1", "home_namespace_id": "1"]]
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func metadata(_ node: Node, tagged: Bool = true) -> [String: Any] {
        var json: [String: Any] = ["name": node.name, "id": node.id, "path_lower": node.display.lowercased(),
                                   "path_display": node.display]
        if node.folder {
            if tagged { json[".tag"] = "folder" }
        } else {
            if tagged { json[".tag"] = "file" }
            json["client_modified"] = Self.iso(node.clientModified)
            json["server_modified"] = Self.iso(node.serverModified)
            json["rev"] = node.rev
            json["size"] = node.data.count
            json["is_downloadable"] = true
            json["content_hash"] = DropboxContentHash.of(node.data)
        }
        return json
    }

    /// A route error whose union member `field` holds a lookup or write error.
    private func error(_ field: String, _ tag: String, conflict: String? = nil) -> Response {
        var inner: [String: Any] = [".tag": tag]
        var summary = "\(field)/\(tag)/"
        if let conflict {
            inner[tag] = [".tag": conflict]
            summary += "\(conflict)/"
        }
        return .json(["error_summary": summary + "..", "error": [".tag": field, field: inner]], status: 409)
    }

    // MARK: Shared links

    private func linkMetadata(_ node: Node, url: String) -> [String: Any] {
        var json: [String: Any] = [
            ".tag": node.folder ? "folder" : "file", "url": url, "name": node.name, "id": node.id,
            "path_lower": node.display.lowercased(),
            "link_permissions": ["can_revoke": true, "visibility_policies": [], "can_set_expiry": false,
                                 "can_remove_expiry": false, "allow_download": true, "can_allow_download": true,
                                 "can_disallow_download": false, "allow_comments": true, "team_restricts_comments": false],
        ]
        if !node.folder {
            json["client_modified"] = Self.iso(node.clientModified)
            json["server_modified"] = Self.iso(node.serverModified)
            json["rev"] = node.rev
            json["size"] = node.data.count
        }
        return json
    }

    private func createLink(_ argument: [String: Any]) -> Response {
        let path = (argument["path"] as? String ?? "").lowercased()
        return state.withLock { s -> Response in
            guard let node = s.nodes[path] else { return error("path", "not_found") }
            if let url = s.links[path] {
                var inner: [String: Any] = [".tag": "shared_link_already_exists"]
                if !s.existingLinkWithoutMetadata {
                    inner["shared_link_already_exists"] = [".tag": "metadata", "metadata": linkMetadata(node, url: url)]
                }
                return .json(["error_summary": "shared_link_already_exists/..", "error": inner], status: 409)
            }
            s.counter += 1
            let url = "https://www.dropbox.com/scl/fi/link\(s.counter)/\(node.name)?dl=0"
            s.links[path] = url
            return .json(linkMetadata(node, url: url))
        }
    }

    private func listLinks(_ argument: [String: Any]) -> Response {
        let path = (argument["path"] as? String ?? "").lowercased()
        return state.withLock { s -> Response in
            let links = s.links[path].flatMap { url in s.nodes[path].map { linkMetadata($0, url: url) } }
            return .json(["links": links.map { [$0] } ?? [], "has_more": false])
        }
    }

    private func listFolder(_ argument: [String: Any]) -> Response {
        let path = (argument["path"] as? String ?? "").lowercased()
        let limit = argument["limit"] as? Int ?? 2000
        return state.withLock { s -> Response in
            if path != "" {
                guard let node = s.nodes[path] else { return error("path", "not_found") }
                guard node.folder else { return error("path", "not_folder") }
            }
            return page(path, offset: 0, limit: limit, s)
        }
    }

    private func page(_ folder: String, offset: Int, limit: Int, _ s: State) -> Response {
        let children = s.nodes.values.filter { parent(of: $0.display.lowercased()) == folder }.sorted { $0.display < $1.display }
        let slice = children.dropFirst(offset).prefix(limit)
        let next = offset + slice.count
        return .json(["entries": slice.map { metadata($0) }, "cursor": "\(folder)|\(next)|\(limit)",
                      "has_more": next < children.count])
    }

    private func listContinue(_ argument: [String: Any]) -> Response {
        let parts = (argument["cursor"] as? String ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let offset = Int(parts[1]), let limit = Int(parts[2]) else {
            return .json(["error_summary": "reset/", "error": [".tag": "reset"]], status: 409)
        }
        return state.withLock { s in page(parts[0], offset: offset, limit: limit, s) }
    }

    private func getMetadata(_ argument: [String: Any]) -> Response {
        let path = (argument["path"] as? String ?? "").lowercased()
        return state.withLock { s in
            guard let node = s.nodes[path] else { return error("path", "not_found") }
            return .json(metadata(node))
        }
    }

    private func createFolder(_ argument: [String: Any]) -> Response {
        let path = argument["path"] as? String ?? ""
        if state.withLock({ $0.nodes[path.lowercased()] }) != nil {
            return error("path", "conflict", conflict: "folder")
        }
        makeFolder(path)
        return .json(["metadata": metadata(node(path)!, tagged: false)])
    }

    private func delete(_ argument: [String: Any]) -> Response {
        let path = (argument["path"] as? String ?? "").lowercased()
        return state.withLock { s -> Response in
            guard let node = s.nodes[path] else { return error("path_lookup", "not_found") }
            if let rev = argument["parent_rev"] as? String, rev != node.rev {
                return error("path_write", "conflict", conflict: "file")
            }
            for key in s.nodes.keys where key == path || key.hasPrefix(path + "/") { s.nodes[key] = nil }
            return .json(["metadata": metadata(node)])
        }
    }

    private func relocate(_ argument: [String: Any], move: Bool) -> Response {
        let from = (argument["from_path"] as? String ?? "").lowercased()
        let toDisplay = argument["to_path"] as? String ?? ""
        let to = toDisplay.lowercased()
        return state.withLock { s -> Response in
            guard s.nodes[from] != nil else { return error("from_lookup", "not_found") }
            if let existing = s.nodes[to], !(move && from == to) {
                return error("to", "conflict", conflict: existing.folder ? "folder" : "file")
            }
            let moved = s.nodes.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
            if move { for key in moved.keys { s.nodes[key] = nil } }
            for (key, var node) in moved {
                let rest = String(node.display.dropFirst(from.count))
                node.display = toDisplay + rest
                if !move {
                    s.counter += 1
                    node.id = "id:\(s.counter)"
                    if !node.folder {
                        node.rev = String(format: "%012x", 0x1000 + s.counter)
                        s.revisions[node.rev] = node.data
                    }
                }
                _ = key
                s.nodes[node.display.lowercased()] = node
            }
            makeParents(to, display: toDisplay, &s)
            return .json(["metadata": metadata(s.nodes[to]!)])
        }
    }

    private func commit(_ path: String, _ data: Data, _ commit: [String: Any]) -> Response? {
        if node(path) != nil { return nil }
        let modified = (commit["client_modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        put(path, data, modified: modified ?? state.withLock { $0.clock })
        return .json(metadata(node(path)!, tagged: false))
    }

    private func hashMismatch(_ argument: [String: Any], _ data: Data) -> Bool {
        guard let hash = argument["content_hash"] as? String else { return false }
        return hash != DropboxContentHash.of(data)
    }

    private func upload(_ argument: [String: Any], _ body: Data) -> Response {
        if hashMismatch(argument, body) {
            return .json(["error_summary": "content_hash_mismatch/", "error": [".tag": "content_hash_mismatch"]], status: 409)
        }
        let path = argument["path"] as? String ?? ""
        state.withLock { $0.uploadedParts += 1 }
        return commit(path, body, argument) ?? .json([
            "error_summary": "path/conflict/file/..",
            "error": [".tag": "path", "reason": [".tag": "conflict", "conflict": [".tag": "file"]], "upload_session_id": "none"],
        ], status: 409)
    }

    private func sessionStart(_ argument: [String: Any], _ body: Data) -> Response {
        if hashMismatch(argument, body) {
            return .json(["error_summary": "content_hash_mismatch/", "error": [".tag": "content_hash_mismatch"]], status: 409)
        }
        let id = "session-\(UUID().uuidString)"
        state.withLock { s in
            s.sessions[id] = body
            s.uploadedParts += 1
        }
        return .json(["session_id": id])
    }

    private func cursor(_ argument: [String: Any]) -> (String, Int)? {
        guard let cursor = argument["cursor"] as? [String: Any], let id = cursor["session_id"] as? String,
              let offset = cursor["offset"] as? Int else { return nil }
        return (id, offset)
    }

    private func lookupFailed(_ tag: String) -> Response {
        .json(["error_summary": "\(tag)/", "error": [".tag": tag]], status: 409)
    }

    private func sessionAppend(_ argument: [String: Any], _ body: Data) -> Response {
        if hashMismatch(argument, body) {
            return .json(["error_summary": "content_hash_mismatch/", "error": [".tag": "content_hash_mismatch"]], status: 409)
        }
        guard let (id, offset) = cursor(argument) else { return lookupFailed("not_found") }
        return state.withLock { s -> Response in
            guard let data = s.sessions[id] else { return lookupFailed("not_found") }
            guard data.count == offset else {
                return .json(["error_summary": "incorrect_offset/", "error": [".tag": "incorrect_offset", "correct_offset": data.count]], status: 409)
            }
            s.sessions[id]!.append(body)
            s.uploadedParts += 1
            return Response(status: 200, body: Data("null".utf8), headers: ["Content-Type": "application/json"])
        }
    }

    private func sessionFinish(_ argument: [String: Any], _ body: Data) -> Response {
        if hashMismatch(argument, body) {
            return .json(["error_summary": "content_hash_mismatch/", "error": [".tag": "content_hash_mismatch"]], status: 409)
        }
        guard let (id, offset) = cursor(argument), let commitInfo = argument["commit"] as? [String: Any] else {
            return lookupFailed("not_found")
        }
        let data: Data? = state.withLock { s in
            guard let data = s.sessions[id], data.count == offset else { return nil }
            s.sessions[id] = nil
            return data + body
        }
        guard let data else {
            return .json(["error_summary": "lookup_failed/not_found/", "error": [".tag": "lookup_failed", "lookup_failed": [".tag": "not_found"]]], status: 409)
        }
        let path = commitInfo["path"] as? String ?? ""
        return commit(path, data, commitInfo) ?? .json([
            "error_summary": "path/conflict/file/..",
            "error": [".tag": "path", "path": [".tag": "conflict", "conflict": [".tag": "file"]]],
        ], status: 409)
    }

    private func download(_ argument: [String: Any], range: String?) -> Response {
        let path = argument["path"] as? String ?? ""
        let found: (Data, Node?)? = state.withLock { s in
            s.downloads += 1
            if path.hasPrefix("rev:") {
                let rev = String(path.dropFirst(4))
                guard let data = s.revisions[rev] else { return nil }
                return (data, s.nodes.values.first { $0.rev == rev })
            }
            guard let node = s.nodes[path.lowercased()], !node.folder else { return nil }
            return (node.data, node)
        }
        guard let (data, node) = found else { return error("path", "not_found") }
        var body = data
        var status = 200
        if let range, range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(bounds.first ?? "") ?? 0
            let upper = min(Int(bounds.count > 1 ? bounds[1] : "") ?? (data.count - 1), data.count - 1)
            if lower >= data.count { return Response(status: 416, body: Data()) }
            body = data.subdata(in: lower..<(upper + 1))
            status = 206
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if let node {
            headers["Dropbox-API-Result"] = DropboxProvider.headerJSON(
                ["name": node.name, "rev": node.rev, "id": node.id])
        }
        return Response(status: status, body: body, headers: headers)
    }
}

/// Answers the browser sign-in through the fake: "opens" the page and comes back like
/// Dropbox would, or gives up.
final class FakeBrowserPrompts: RemotePrompts {
    let dropbox: FakeDropbox
    let giveUp: Bool
    let signIns = Mutex<[BrowserSignIn]>([])
    /// The pages the browser showed after signing in.
    let returnPages = Mutex<[String]>([])

    init(_ dropbox: FakeDropbox, giveUp: Bool = false) {
        self.dropbox = dropbox
        self.giveUp = giveUp
    }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer { .cancel }
    func secret(_ request: SecretRequest) async -> SecretAnswer? { nil }

    func browserSignIn(_ request: BrowserSignIn) async {
        signIns.withLock { $0.append(request) }
        if giveUp { return }
        if let back = dropbox.authorize(request.url) {
            // Like a browser: opens the return page Basil serves on this Mac.
            Task {
                try? await Task.sleep(for: .milliseconds(20))
                if let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: back) {
                    returnPages.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
                }
            }
        }
        // Waits like the sheet does until the sign-in came back.
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
