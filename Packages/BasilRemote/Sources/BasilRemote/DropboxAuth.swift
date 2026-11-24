import BasilVFS
import CryptoKit
import Foundation
import Synchronization
@preconcurrency import SwiftyDropbox

// Signing in to Dropbox: OAuth 2 code flow with PKCE in the user's browser (no app secret),
// short-lived access tokens refreshed with the refresh token, which is kept in the Keychain.
// This is Basil's own code rather than the SDK's DropboxClientsManager, so tokens live under
// Basil's Keychain keys ("dropbox:<account id>") and several accounts can be open at once.

/// Where Dropbox's servers are. Tests point them at a local fake.
public struct DropboxHosts: Sendable, Equatable {
    /// The sign-in pages ("https://www.dropbox.com").
    public var web: String
    /// RPC calls and the token endpoint ("https://api.dropbox.com").
    public var api: String
    /// Uploads and downloads ("https://api-content.dropbox.com").
    public var content: String
    /// Long-polls for changes ("https://notify.dropboxapi.com").
    public var notify: String
    /// How long one long-poll waits for a change, in seconds (30 to 480; tests use less).
    public var longpollTimeout: Int

    public init(web: String, api: String, content: String, notify: String = "https://notify.dropboxapi.com",
                longpollTimeout: Int = 120) {
        self.web = web
        self.api = api
        self.content = content
        self.notify = notify
        self.longpollTimeout = longpollTimeout
    }

    /// The SDK's own hosts.
    public static let dropbox = DropboxHosts(web: "https://www.dropbox.com", api: "https://api.dropbox.com",
                                             content: "https://api-content.dropbox.com")

    var baseHosts: BaseHosts { BaseHosts(apiHost: api, contentHost: content, notifyHost: notify) }
}

/// What a sign-in or a refresh returns.
struct DropboxToken: Sendable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    var accountID: String
    /// The permissions Dropbox granted (the "scope" of a sign-in answer); nil after a refresh.
    var scopes: Set<String>? = nil
}

/// The sign-in failed in a way the user should hear about.
struct DropboxAuthError: Error, LocalizedError {
    /// The refresh token no longer works (access removed on dropbox.com, or the token revoked).
    var invalidGrant: Bool
    var message: String
    var errorDescription: String? { message }
}

/// The permissions Basil asks for (see db_privacypolicy.md).
enum DropboxScopes {
    static let all = ["account_info.read", "files.metadata.read", "files.metadata.write",
                      "files.content.read", "files.content.write", "sharing.read", "sharing.write"]

    /// Whether a sign-in that granted `granted` (a space-separated list) has every scope Basil asks for.
    static func covered(by granted: String?) -> Bool {
        guard let granted else { return false }
        return Set(all).isSubset(of: Set(granted.split(separator: " ").map(String.init)))
    }
}

/// A PKCE verifier and its S256 challenge (RFC 7636).
struct OAuthPKCE {
    let verifier: String
    let challenge: String

    init() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        verifier = String((0..<128).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random value for the `state` parameter.
    static func state() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }
}

/// The token endpoint: exchanging a code, refreshing, revoking.
struct DropboxAuth: Sendable {
    let appKey: String
    let hosts: DropboxHosts
    let session: URLSession

    /// The address Dropbox sends the browser back to: Basil's sign-in return page on this Mac
    /// (`SignInReturnServer`). It must be listed under Redirect URIs in the App Console.
    static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/dropbox" }

    func authorizationURL(pkce: OAuthPKCE, state: String, redirect: String) -> URL {
        var components = URLComponents(string: hosts.web + "/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: DropboxScopes.all.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    func exchange(code: String, pkce: OAuthPKCE, redirect: String) async throws -> DropboxToken {
        let json = try await post(["grant_type": "authorization_code", "code": code,
                                   "code_verifier": pkce.verifier, "redirect_uri": redirect])
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let account = json["account_id"] as? String else {
            throw DropboxAuthError(invalidGrant: false, message: "Dropbox sent an incomplete sign-in answer")
        }
        let seconds = (json["expires_in"] as? Double) ?? 14400
        let scopes = (json["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) }
        return DropboxToken(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(seconds),
                            accountID: account, scopes: scopes)
    }

    /// A new access token for a refresh token. The answer has no refresh token or account; the
    /// caller keeps those.
    func refresh(_ refreshToken: String) async throws -> (accessToken: String, expires: Date) {
        let json = try await post(["grant_type": "refresh_token", "refresh_token": refreshToken])
        guard let access = json["access_token"] as? String else {
            throw DropboxAuthError(invalidGrant: false, message: "Dropbox sent an incomplete answer to a token refresh")
        }
        let seconds = (json["expires_in"] as? Double) ?? 14400
        return (access, Date().addingTimeInterval(seconds))
    }

    /// Revokes the access token and with it the refresh token it came from (auth/token/revoke).
    func revoke(accessToken: String) async throws {
        var request = URLRequest(url: URL(string: hosts.api + "/2/auth/token/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 401: the token was no longer valid, which is what revoking wants.
        guard status == 200 || status == 401 else {
            throw DropboxAuthError(invalidGrant: false, message: "Dropbox did not revoke the sign-in (HTTP \(status))")
        }
    }

    private func post(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: hosts.api + "/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var all = parameters
        all["client_id"] = appKey
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = all.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DropboxAuthError(invalidGrant: false, message: "Could not reach Dropbox: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? "HTTP \(status)"
            let description = json["error_description"] as? String
            throw DropboxAuthError(invalidGrant: code == "invalid_grant",
                                   message: "Dropbox refused the sign-in: " + (description.map { "\($0) (\(code))" } ?? code))
        }
        return json
    }
}

/// Redirects from the browser ("http://localhost:21745/dropbox?code=...&state=..."), handed
/// over by the sign-in return page to the sign-in waiting for that state.
enum SignInRedirects {
    private static let waiting = Mutex<[String: CheckedContinuation<URL, Error>]>([:])

    /// True when a sign-in was waiting for this address (its state).
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value
        let continuations: [CheckedContinuation<URL, Error>] = waiting.withLock { map in
            if let state, let one = map.removeValue(forKey: state) { return [one] }
            // A cancel address carries no state: it ends every sign-in waiting.
            if url.path == "/cancel" {
                let all = Array(map.values)
                map.removeAll()
                return all
            }
            return []
        }
        for continuation in continuations {
            if url.path == "/cancel" { continuation.resume(throwing: RemoteCancelled()) } else { continuation.resume(returning: url) }
        }
        return !continuations.isEmpty
    }

    /// Waits for the redirect with this state; cancelling the task stops waiting.
    static func wait(for state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = Task.isCancelled
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.withLock { $0[state] = continuation }
                }
            }
        } onCancel: {
            let continuation = waiting.withLock { $0.removeValue(forKey: state) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// The access token of one account, refreshed before it runs out. Serves the SDK (its
/// `AccessTokenProvider`) and Basil's own downloads.
final class DropboxTokens: AccessTokenProvider, @unchecked Sendable {
    let auth: DropboxAuth
    let accountID: String
    let refreshToken: String
    private struct State {
        var accessToken: String
        var expires: Date
        var refreshing: Task<String, Error>?
    }
    private let state: Mutex<State>

    init(auth: DropboxAuth, token: DropboxToken) {
        self.auth = auth
        accountID = token.accountID
        refreshToken = token.refreshToken
        state = Mutex(State(accessToken: token.accessToken, expires: token.expires))
    }

    var accessToken: String { state.withLock { $0.accessToken } }

    /// A token valid for at least five more minutes.
    func current() async throws -> String {
        let task: Task<String, Error>? = state.withLock { s in
            if s.expires.timeIntervalSinceNow > 300 { return nil }
            if let running = s.refreshing { return running }
            let auth = auth
            let refreshToken = refreshToken
            let task = Task { [weak self] () throws -> String in
                do {
                    let fresh = try await auth.refresh(refreshToken)
                    self?.state.withLock { s in
                        s.accessToken = fresh.accessToken
                        s.expires = fresh.expires
                        s.refreshing = nil
                    }
                    return fresh.accessToken
                } catch {
                    self?.state.withLock { $0.refreshing = nil }
                    throw error
                }
            }
            s.refreshing = task
            return task
        }
        guard let task else { return accessToken }
        return try await task.value
    }

    /// Makes the next request refresh first (after the server said the token expired).
    func expire() {
        state.withLock { $0.expires = .distantPast }
    }

    func refreshAccessTokenIfNecessary(completion: @escaping DropboxOAuthCompletion) {
        nonisolated(unsafe) let completion = completion
        let needed = state.withLock { $0.expires.timeIntervalSinceNow <= 300 }
        guard needed else { return completion(nil) }
        let accountID = accountID
        let refreshToken = refreshToken
        Task {
            do {
                let token = try await current()
                completion(.success(DropboxAccessToken(accessToken: token, uid: accountID, refreshToken: refreshToken,
                                                       tokenExpirationTimestamp: state.withLock { $0.expires.timeIntervalSince1970 })))
            } catch let error as DropboxAuthError {
                completion(.error(error.invalidGrant ? .invalidGrant : .unknown, error.message))
            } catch {
                completion(.error(.unknown, error.localizedDescription))
            }
        }
    }
}
