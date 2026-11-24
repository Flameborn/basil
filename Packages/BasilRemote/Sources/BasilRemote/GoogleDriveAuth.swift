import BasilVFS
import Foundation
import Synchronization

// Signing in to Google: OAuth 2 code flow with PKCE in the user's browser, for an OAuth client
// of the type "Desktop app". Google sends the browser back to a loopback address on any port
// ("http://127.0.0.1:<port>/google"), so the return page takes a free port each time. A desktop
// client also has a client secret, which Google documents as not secret for installed apps; it
// is built into the app like the client ID. The refresh token is kept in the Keychain as
// "gdrive:<permission id>".

/// Where Google's servers are. Tests point them at a local fake.
public struct GoogleHosts: Sendable, Equatable {
    /// The sign-in pages ("https://accounts.google.com").
    public var accounts: String
    /// The token and revoke endpoints ("https://oauth2.googleapis.com").
    public var oauth: String
    /// The Drive API and its uploads ("https://www.googleapis.com").
    public var api: String
    /// How often a watched folder asks Drive's changes feed, in seconds (tests use less).
    public var changesInterval: Double

    public init(accounts: String, oauth: String, api: String, changesInterval: Double = 10) {
        self.accounts = accounts
        self.oauth = oauth
        self.api = api
        self.changesInterval = changesInterval
    }

    public static let google = GoogleHosts(accounts: "https://accounts.google.com", oauth: "https://oauth2.googleapis.com",
                                           api: "https://www.googleapis.com")
}

/// The OAuth client Basil signs in as (Google Cloud Console, Credentials, type Desktop app).
public struct GoogleClient: Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

/// The permissions Basil asks for: every file in the user's Drive (a "restricted" scope).
enum GoogleScopes {
    static let drive = "https://www.googleapis.com/auth/drive"
    static let all = [drive]

    static func covered(by granted: String?) -> Bool {
        guard let granted else { return false }
        return Set(all).isSubset(of: Set(granted.split(separator: " ").map(String.init)))
    }
}

/// What a sign-in or a refresh returns.
struct GoogleToken: Sendable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    /// The scopes Google granted (a sign-in answer's "scope"); nil after a refresh.
    var scopes: String?
}

struct GoogleAuthError: Error, LocalizedError {
    /// The refresh token no longer works (access removed in the Google account, or revoked).
    var invalidGrant: Bool
    var message: String
    var errorDescription: String? { message }
}

/// The token endpoint: exchanging a code, refreshing, revoking.
struct GoogleAuth: Sendable {
    let client: GoogleClient
    let hosts: GoogleHosts
    let session: URLSession

    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/google" }

    func authorizationURL(pkce: OAuthPKCE, state: String, redirect: String, account: String?) -> URL {
        var components = URLComponents(string: hosts.accounts + "/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleScopes.all.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Google hands out a refresh token only when the user is asked; ask every time.
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        if let account, !account.isEmpty { items.append(URLQueryItem(name: "login_hint", value: account)) }
        components.queryItems = items
        // URLComponents leaves "+" alone, which a form decoder reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func exchange(code: String, pkce: OAuthPKCE, redirect: String) async throws -> GoogleToken {
        let json = try await post("/token", ["grant_type": "authorization_code", "code": code,
                                             "code_verifier": pkce.verifier, "redirect_uri": redirect])
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw GoogleAuthError(invalidGrant: false, message: "Google sent an incomplete sign-in answer")
        }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        return GoogleToken(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(seconds),
                           scopes: json["scope"] as? String)
    }

    func refresh(_ refreshToken: String) async throws -> (accessToken: String, expires: Date) {
        let json = try await post("/token", ["grant_type": "refresh_token", "refresh_token": refreshToken])
        guard let access = json["access_token"] as? String else {
            throw GoogleAuthError(invalidGrant: false, message: "Google sent an incomplete answer to a token refresh")
        }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        return (access, Date().addingTimeInterval(seconds))
    }

    /// Revokes a refresh token (and the access tokens made from it).
    func revoke(_ token: String) async throws {
        var request = URLRequest(url: URL(string: hosts.oauth + "/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("token=" + Self.formEncode(token)).utf8)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 400: the token was no longer valid, which is what revoking wants.
        guard status == 200 || status == 400 else {
            throw GoogleAuthError(invalidGrant: false, message: "Google did not revoke the sign-in (HTTP \(status))")
        }
    }

    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func post(_ path: String, _ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: hosts.oauth + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var all = parameters
        all["client_id"] = client.id
        all["client_secret"] = client.secret
        request.httpBody = all.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleAuthError(invalidGrant: false, message: "Could not reach Google: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? "HTTP \(status)"
            let description = json["error_description"] as? String
            throw GoogleAuthError(invalidGrant: code == "invalid_grant",
                                  message: "Google refused the sign-in: " + (description.map { "\($0) (\(code))" } ?? code))
        }
        return json
    }
}

/// The access token of one account, refreshed five minutes before it runs out (one refresh at
/// a time).
final class GoogleTokens: Sendable {
    let auth: GoogleAuth
    let refreshToken: String
    private struct State {
        var accessToken: String
        var expires: Date
        var refreshing: Task<String, Error>?
    }
    private let state: Mutex<State>

    init(auth: GoogleAuth, refreshToken: String, accessToken: String, expires: Date) {
        self.auth = auth
        self.refreshToken = refreshToken
        state = Mutex(State(accessToken: accessToken, expires: expires))
    }

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
        guard let task else { return state.withLock { $0.accessToken } }
        return try await task.value
    }

    /// The next request refreshes first (the server said the token is no longer valid).
    func expire() {
        state.withLock { $0.expires = .distantPast }
    }
}
