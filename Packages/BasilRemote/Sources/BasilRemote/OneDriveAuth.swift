import BasilVFS
import Foundation
import Synchronization

// Signing in to Microsoft: OAuth 2 code flow with PKCE in the user's browser, for an app
// registered in Microsoft Entra as a public client ("Mobile and desktop applications", no
// secret) for personal and work or school accounts (the "common" endpoint). Microsoft ignores
// the port of http://localhost redirects, so the return page takes a free port each time; the
// path must match the registered "http://localhost/onedrive". Every refresh hands out a new
// refresh token, which replaces the stored one ("onedrive:<user id>" in the Keychain).
// Microsoft has no call to revoke one sign-in: removing a connection forgets the token, and the
// user removes Basil from the account's app permissions.

/// Where Microsoft's servers are. Tests point them at a local fake.
public struct MicrosoftHosts: Sendable, Equatable {
    /// The sign-in and token endpoints ("https://login.microsoftonline.com").
    public var login: String
    /// Microsoft Graph ("https://graph.microsoft.com").
    public var graph: String

    public init(login: String, graph: String) {
        self.login = login
        self.graph = graph
    }

    public static let microsoft = MicrosoftHosts(login: "https://login.microsoftonline.com", graph: "https://graph.microsoft.com")
}

/// The permissions Basil asks for: every file the user can reach, a refresh token, and the
/// account's name and email address.
enum MicrosoftScopes {
    static let files = "Files.ReadWrite.All"
    static let all = [files, "offline_access", "User.Read"]

    /// Microsoft writes granted Graph scopes with or without "https://graph.microsoft.com/".
    static func covered(by granted: String?) -> Bool {
        guard let granted else { return false }
        let names = Set(granted.split(separator: " ").map {
            $0.replacingOccurrences(of: "https://graph.microsoft.com/", with: "").lowercased()
        })
        return names.contains(files.lowercased())
    }
}

struct MicrosoftToken: Sendable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    var scopes: String?
}

struct MicrosoftAuthError: Error, LocalizedError {
    /// The refresh token no longer works (access removed, password changed, expired).
    var invalidGrant: Bool
    var message: String
    var errorDescription: String? { message }
}

/// The token endpoint of the "common" tenant: exchanging a code, refreshing.
struct MicrosoftAuth: Sendable {
    let clientID: String
    let hosts: MicrosoftHosts
    let session: URLSession

    static let tenant = "common"

    static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/onedrive" }

    func authorizationURL(pkce: OAuthPKCE, state: String, redirect: String, account: String?) -> URL {
        var components = URLComponents(string: hosts.login + "/\(Self.tenant)/oauth2/v2.0/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: MicrosoftScopes.all.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let account, !account.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: account))
        } else {
            // Lets the user pick between a personal and a work account signed in in the browser.
            items.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        components.queryItems = items
        // URLComponents leaves "+" alone, which a form decoder reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func exchange(code: String, pkce: OAuthPKCE, redirect: String) async throws -> MicrosoftToken {
        let json = try await post(["grant_type": "authorization_code", "code": code, "code_verifier": pkce.verifier,
                                   "redirect_uri": redirect, "scope": MicrosoftScopes.all.joined(separator: " ")])
        return try token(json, keeping: nil)
    }

    /// A fresh access token and the refresh token that replaces `refreshToken`.
    func refresh(_ refreshToken: String) async throws -> MicrosoftToken {
        let json = try await post(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                   "scope": MicrosoftScopes.all.joined(separator: " ")])
        return try token(json, keeping: refreshToken)
    }

    private func token(_ json: [String: Any], keeping old: String?) throws -> MicrosoftToken {
        guard let access = json["access_token"] as? String, let refresh = (json["refresh_token"] as? String) ?? old else {
            throw MicrosoftAuthError(invalidGrant: false, message: "Microsoft sent an incomplete sign-in answer")
        }
        let seconds = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return MicrosoftToken(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(seconds),
                              scopes: json["scope"] as? String)
    }

    private func post(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: hosts.login + "/\(Self.tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var all = parameters
        all["client_id"] = clientID
        request.httpBody = all.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(GoogleAuth.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MicrosoftAuthError(invalidGrant: false, message: "Could not reach Microsoft: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? "HTTP \(status)"
            // The first line of Microsoft's description is the readable part ("AADSTS70000: ...").
            let description = (json["error_description"] as? String)?.split(separator: "\n").first.map(String.init)
            throw MicrosoftAuthError(invalidGrant: code == "invalid_grant" || code == "interaction_required",
                                     message: "Microsoft refused the sign-in: " + (description.map { "\($0) (\(code))" } ?? code))
        }
        return json
    }
}

/// The access token of one account, refreshed five minutes before it runs out (one refresh at
/// a time). Each refresh brings a new refresh token, handed to `rotated` to be stored.
final class MicrosoftTokens: Sendable {
    let auth: MicrosoftAuth
    private let rotated: @Sendable (String) -> Void
    private struct State {
        var refreshToken: String
        var accessToken: String
        var expires: Date
        var refreshing: Task<String, Error>?
    }
    private let state: Mutex<State>

    init(auth: MicrosoftAuth, token: MicrosoftToken, rotated: @escaping @Sendable (String) -> Void) {
        self.auth = auth
        self.rotated = rotated
        state = Mutex(State(refreshToken: token.refreshToken, accessToken: token.accessToken, expires: token.expires))
    }

    var refreshToken: String { state.withLock { $0.refreshToken } }

    func current() async throws -> String {
        let task: Task<String, Error>? = state.withLock { s in
            if s.expires.timeIntervalSinceNow > 300 { return nil }
            if let running = s.refreshing { return running }
            let auth = auth
            let refreshToken = s.refreshToken
            let rotated = rotated
            let task = Task { [weak self] () throws -> String in
                do {
                    let fresh = try await auth.refresh(refreshToken)
                    self?.state.withLock { s in
                        s.accessToken = fresh.accessToken
                        s.expires = fresh.expires
                        s.refreshToken = fresh.refreshToken
                        s.refreshing = nil
                    }
                    if fresh.refreshToken != refreshToken { rotated(fresh.refreshToken) }
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
