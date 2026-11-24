import BasilCore
import BasilVFS
import Foundation

/// Connects to Google Drive accounts. Signing in happens on accounts.google.com in the browser
/// (OAuth 2 with PKCE, see `GoogleAuth`); Basil never sees the password. A saved connection
/// holds the account's permission ID in `host` and its email address in `user` once it signed
/// in, so several accounts can be saved. The refresh token is kept in `secrets` (the Keychain)
/// as "gdrive:<permission id>"; deleting the last saved connection of an account revokes it.
public struct GoogleDriveConnector: RemoteConnector {
    let auth: GoogleAuth
    let secrets: any SecretStore

    /// `client`: the OAuth client from the Google Cloud Console (type Desktop app), set at
    /// build time.
    public init(client: GoogleClient, secrets: any SecretStore, hosts: GoogleHosts = .google) {
        auth = GoogleAuth(client: client, hosts: hosts, session: URLSession(configuration: .ephemeral))
        self.secrets = secrets
    }

    public var service: ProviderID { .googleDrive }
    public var displayName: String { "Google Drive" }
    public var defaultPort: Int { 443 }
    public var logins: [RemoteLogin] { [.automatic] }
    public var automaticLoginTitle: String { "Google website" }
    public var usesServerAddress: Bool { false }
    public var pathPlaceholder: String? { "/My Drive" }
    /// The export format of each kind of Google document.
    public var options: [RemoteOption] { DriveExportFormats.options }
    public var loginNote: String? {
        "Connecting opens accounts.google.com in your browser, where you sign in and allow Basil. Basil never sees your Google password; its sign-in is kept in the Keychain."
    }

    static func keychainKey(_ account: String) -> String { "gdrive:\(account)" }
    static func scopesKey(_ account: String) -> String { "gdrive:\(account):scopes" }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let saved = target.host.trimmingCharacters(in: .whitespaces)
        var token: GoogleToken?
        if !saved.isEmpty, let refresh = secrets.secret(for: Self.keychainKey(saved)),
           GoogleScopes.covered(by: secrets.secret(for: Self.scopesKey(saved))) {
            do {
                let fresh = try await auth.refresh(refresh)
                token = GoogleToken(accessToken: fresh.accessToken, refreshToken: refresh, expires: fresh.expires)
            } catch let error as GoogleAuthError where error.invalidGrant {
                // Access was removed in the Google account (or the token expired): sign in again.
                secrets.remove(for: Self.keychainKey(saved))
            }
        }
        let fresh = token == nil
        let signedIn: GoogleToken
        if let token { signedIn = token } else { signedIn = try await signIn(prompts: prompts, account: target.user) }
        let granted = signedIn.scopes ?? GoogleScopes.all.joined(separator: " ")
        if fresh, !GoogleScopes.covered(by: granted) {
            // Google's consent page lets the user untick the permission.
            try? await auth.revoke(signedIn.refreshToken)
            throw VFSError.failed("Basil was not allowed to see and change your files in Google Drive. Connect again and allow that.")
        }
        let tokens = GoogleTokens(auth: auth, refreshToken: signedIn.refreshToken, accessToken: signedIn.accessToken,
                                  expires: signedIn.expires)
        let client = HTTPClient(endpoint: Self.endpoint(auth.hosts.api))
        let about: About
        do { about = try await Self.about(client: client, tokens: tokens, hosts: auth.hosts) } catch {
            client.close()
            throw error
        }
        if fresh {
            secrets.save(signedIn.refreshToken, for: Self.keychainKey(about.permissionID))
            secrets.save(granted, for: Self.scopesKey(about.permissionID))
        }
        var updated = target
        updated.host = about.permissionID
        updated.user = about.email
        updated.port = nil
        updated.authentication = .automatic
        let provider = GoogleDriveProvider(client: client, tokens: tokens, hosts: auth.hosts, email: about.email,
                                           displayName: about.name, rootID: about.rootID,
                                           signedInTarget: updated == target ? nil : updated,
                                           formats: DriveExportFormats(options: target.options))
        var start = target.path?.trimmingCharacters(in: .whitespaces) ?? ""
        if start.isEmpty || start == "/" { start = "/" + DriveNames.myDrive }
        if !start.hasPrefix("/") { start = "/" + start }
        return (provider, VFSPath(location: provider.location, path: start))
    }

    /// The HTTP endpoint of an API address ("https://www.googleapis.com").
    static func endpoint(_ address: String) -> HTTPEndpoint {
        let url = URL(string: address)
        let secure = url?.scheme != "http"
        let port = url?.port ?? (secure ? 443 : 80)
        return HTTPEndpoint(service: .googleDrive, secure: secure, host: url?.host ?? "www.googleapis.com", port: port,
                            defaultPort: secure ? 443 : 80, user: "")
    }

    struct About {
        var email: String
        var name: String
        var permissionID: String
        var rootID: String
    }

    /// The signed-in account and My Drive's top folder.
    static func about(client: HTTPClient, tokens: GoogleTokens, hosts: GoogleHosts) async throws -> About {
        func get(_ path: String, fields: String) async throws -> [String: Any] {
            let token = try await tokens.current()
            let url = URL(string: hosts.api + "/drive/v3" + path + "?fields=" + GoogleAuth.formEncode(fields))!
            let response: HTTPResponse
            do {
                response = try await client.send("GET", url, headers: ["Authorization": "Bearer \(token)"])
            } catch is HTTPUnauthorized {
                throw VFSError.failed("Google Drive did not accept the sign-in")
            }
            guard response.isSuccess else {
                if DriveProblem(response).reason == "accessNotConfigured" || DriveProblem(response).reason == "SERVICE_DISABLED" {
                    throw VFSError.failed("The Google Drive API is not enabled for Basil's Google Cloud project: \(DriveProblem(response).message)")
                }
                throw VFSError.failed("Reading the Google Drive account failed: \(DriveProblem(response).message)")
            }
            return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        }
        let about = try await get("/about", fields: "user(displayName,emailAddress,permissionId)")
        let user = about["user"] as? [String: Any] ?? [:]
        guard let email = user["emailAddress"] as? String, let permission = user["permissionId"] as? String else {
            throw VFSError.failed("Google Drive did not say which account signed in")
        }
        let root = try await get("/files/root", fields: "id")
        guard let rootID = root["id"] as? String else { throw VFSError.failed("Google Drive did not name My Drive's folder") }
        return About(email: email, name: user["displayName"] as? String ?? email, permissionID: permission, rootID: rootID)
    }

    /// Signs in in the browser: opens Google's page through `prompts` and waits for the
    /// redirect back to Basil (a free port on 127.0.0.1), or for the user to give up.
    func signIn(prompts: any RemotePrompts, account: String?) async throws -> GoogleToken {
        let pkce = OAuthPKCE()
        let state = OAuthPKCE.state()
        let server = try SignInReturnServer(port: 0, service: displayName) { url in
            Self.returnPage(url, matched: url.path == "/google" && SignInRedirects.handle(url))
        }
        defer { server.stop() }
        let redirect = GoogleAuth.redirectURI(port: server.port)
        let request = BrowserSignIn(service: displayName,
                                    url: auth.authorizationURL(pkce: pkce, state: state, redirect: redirect, account: account),
                                    account: account)
        enum Outcome: Sendable { case redirect(URL), cancelled }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .redirect(try await SignInRedirects.wait(for: state)) } catch { return .cancelled }
            }
            group.addTask {
                await prompts.browserSignIn(request)
                return .cancelled
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        guard case .redirect(let url) = outcome else { throw RemoteCancelled() }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw RemoteCancelled() }
            throw GoogleAuthError(invalidGrant: false, message: "Google refused the sign-in: \(value("error_description") ?? error)")
        }
        guard let code = value("code") else {
            throw GoogleAuthError(invalidGrant: false, message: "Google sent no sign-in code")
        }
        return try await auth.exchange(code: code, pkce: pkce, redirect: redirect)
    }

    /// What the browser shows when it comes back.
    static func returnPage(_ url: URL, matched: Bool) -> SignInReturnServer.Page {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let error = items.first { $0.name == "error" }?.value
        if matched, error == "access_denied" {
            return .init(title: "Basil was not allowed", message: "You chose not to allow Basil. You can close this tab.")
        }
        if matched, let error {
            let detail = items.first { $0.name == "error_description" }?.value ?? error
            return .init(title: "Google did not sign in", message: "Google said: \(detail). You can close this tab and try again in Basil.")
        }
        if matched {
            return .init(title: "Signed in to Google Drive", message: "Basil is now authorised. You can close this tab and go back to Basil.")
        }
        return .init(title: "This sign-in has ended",
                     message: "Basil is no longer waiting for it. If you are not connected yet, connect again in Basil.")
    }

    /// Revokes the account's sign-in and removes it from the Keychain, unless another saved
    /// connection uses the same account.
    public func forget(_ target: RemoteTarget, remaining: [RemoteTarget]) async {
        let account = target.host.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty,
              !remaining.contains(where: { $0.service == .googleDrive && $0.host == account }) else { return }
        let key = Self.keychainKey(account)
        guard let refresh = secrets.secret(for: key) else { return }
        secrets.remove(for: key)
        secrets.remove(for: Self.scopesKey(account))
        try? await auth.revoke(refresh)
    }
}
