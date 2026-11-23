import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Connects to OneDrive (personal, and work or school accounts). Signing in happens on
/// login.microsoftonline.com in the browser (OAuth 2 with PKCE, see `MicrosoftAuth`); Basil
/// never sees the password. A saved connection holds the account's user ID in `host` and its
/// email address in `user` once it signed in, so several accounts can be saved. The refresh
/// token is kept in `secrets` (the Keychain) as "onedrive:<user id>" and replaced by the new one
/// every refresh brings; deleting the last saved connection of an account removes it.
public struct OneDriveConnector: RemoteConnector {
    let auth: MicrosoftAuth
    let secrets: any SecretStore

    /// `clientID`: the application (client) ID of the app registered in Microsoft Entra, set at
    /// build time.
    public init(clientID: String, secrets: any SecretStore, hosts: MicrosoftHosts = .microsoft) {
        auth = MicrosoftAuth(clientID: clientID, hosts: hosts, session: URLSession(configuration: .ephemeral))
        self.secrets = secrets
    }

    public var service: ProviderID { .oneDrive }
    public var displayName: String { "OneDrive" }
    public var defaultPort: Int { 443 }
    public var logins: [RemoteLogin] { [.automatic] }
    public var automaticLoginTitle: String { "Microsoft website" }
    public var usesServerAddress: Bool { false }
    public var pathPlaceholder: String? { "/Documents" }
    public var loginNote: String? {
        "Connecting opens login.microsoftonline.com in your browser, where you sign in and allow Basil. Basil never sees your Microsoft password; its sign-in is kept in the Keychain."
    }

    static func keychainKey(_ account: String) -> String { "onedrive:\(account)" }
    static func scopesKey(_ account: String) -> String { "onedrive:\(account):scopes" }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let saved = target.host.trimmingCharacters(in: .whitespaces)
        var token: MicrosoftToken?
        if !saved.isEmpty, let refresh = secrets.secret(for: Self.keychainKey(saved)),
           MicrosoftScopes.covered(by: secrets.secret(for: Self.scopesKey(saved))) {
            do {
                token = try await auth.refresh(refresh)
            } catch let error as MicrosoftAuthError where error.invalidGrant {
                // Access was removed, or the sign-in ended: sign in again.
                secrets.remove(for: Self.keychainKey(saved))
            }
        }
        let fresh = token == nil
        let signedIn: MicrosoftToken
        if let token { signedIn = token } else { signedIn = try await signIn(prompts: prompts, account: target.user) }
        let granted = fresh ? (signedIn.scopes ?? MicrosoftScopes.all.joined(separator: " ")) : nil
        if let granted, !MicrosoftScopes.covered(by: granted) {
            throw VFSError.failed("Basil was not allowed to see and change your files in OneDrive. Connect again and allow that.")
        }
        let client = HTTPClient(endpoint: Self.endpoint(auth.hosts.graph))
        let account: Account
        // Until the account is known, a new refresh token is kept by the token holder only.
        let key = Mutex<String?>(saved.isEmpty || fresh ? nil : Self.keychainKey(saved))
        let secrets = secrets
        let tokens = MicrosoftTokens(auth: auth, token: signedIn) { rotated in
            if let key = key.withLock({ $0 }) { secrets.save(rotated, for: key) }
        }
        do { account = try await Self.account(client: client, tokens: tokens, hosts: auth.hosts) } catch {
            client.close()
            throw error
        }
        key.withLock { $0 = Self.keychainKey(account.userID) }
        // The refresh token may have been replaced by now (connecting refreshes, so do requests).
        secrets.save(tokens.refreshToken, for: Self.keychainKey(account.userID))
        if let granted { secrets.save(granted, for: Self.scopesKey(account.userID)) }
        var updated = target
        updated.host = account.userID
        updated.user = account.email
        updated.port = nil
        updated.authentication = .automatic
        let provider = OneDriveProvider(client: client, tokens: tokens, hosts: auth.hosts, email: account.email,
                                        displayName: account.name, driveID: account.driveID, rootID: account.rootID,
                                        business: account.business, signedInTarget: updated == target ? nil : updated)
        var start = target.path?.trimmingCharacters(in: .whitespaces) ?? ""
        if start.isEmpty { start = "/" }
        if !start.hasPrefix("/") { start = "/" + start }
        return (provider, VFSPath(location: provider.location, path: start))
    }

    /// The HTTP endpoint of Graph's address ("https://graph.microsoft.com").
    static func endpoint(_ address: String) -> HTTPEndpoint {
        let url = URL(string: address)
        let secure = url?.scheme != "http"
        let port = url?.port ?? (secure ? 443 : 80)
        return HTTPEndpoint(service: .oneDrive, secure: secure, host: url?.host ?? "graph.microsoft.com", port: port,
                            defaultPort: secure ? 443 : 80, user: "")
    }

    struct Account {
        var userID: String
        var email: String
        var name: String
        var driveID: String
        var rootID: String
        var business: Bool
    }

    /// The signed-in user and their drive.
    static func account(client: HTTPClient, tokens: MicrosoftTokens, hosts: MicrosoftHosts) async throws -> Account {
        func get(_ path: String, select: String) async throws -> [String: Any] {
            let token: String
            do { token = try await tokens.current() } catch let error as MicrosoftAuthError {
                throw VFSError.failed(error.message)
            }
            let url = URL(string: hosts.graph + "/v1.0" + path + "?$select=" + GoogleAuth.formEncode(select))!
            let response: HTTPResponse
            do {
                response = try await client.send("GET", url, headers: ["Authorization": "Bearer \(token)"])
            } catch is HTTPUnauthorized {
                throw VFSError.failed("Microsoft Graph did not accept the sign-in")
            }
            guard response.isSuccess else {
                let problem = GraphProblem(response)
                if path == "/me/drive", response.status == 404 || problem.code == "ResourceNotFound" || problem.code == "itemNotFound" {
                    throw VFSError.failed("This Microsoft account has no OneDrive (\(problem.message))")
                }
                throw VFSError.failed("Reading the Microsoft account failed: \(problem.message)")
            }
            return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        }
        let me = try await get("/me", select: "id,displayName,mail,userPrincipalName")
        guard let id = me["id"] as? String else { throw VFSError.failed("Microsoft did not say which account signed in") }
        let mail = (me["mail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = mail ?? (me["userPrincipalName"] as? String) ?? id
        let drive = try await get("/me/drive", select: "id,driveType")
        let root = try await get("/me/drive/root", select: "id")
        guard let driveID = drive["id"] as? String, let rootID = root["id"] as? String else {
            throw VFSError.failed("OneDrive did not name the account's drive")
        }
        return Account(userID: id, email: email, name: me["displayName"] as? String ?? email, driveID: driveID,
                       rootID: rootID, business: (drive["driveType"] as? String) != "personal")
    }

    /// Signs in in the browser: opens Microsoft's page through `prompts` and waits for the
    /// redirect back to Basil (a free port on localhost), or for the user to give up.
    func signIn(prompts: any RemotePrompts, account: String?) async throws -> MicrosoftToken {
        let pkce = OAuthPKCE()
        let state = OAuthPKCE.state()
        let server = try SignInReturnServer(port: 0, service: displayName) { url in
            Self.returnPage(url, matched: url.path == "/onedrive" && SignInRedirects.handle(url))
        }
        defer { server.stop() }
        let redirect = MicrosoftAuth.redirectURI(port: server.port)
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
            // The user said no (or closed the consent page).
            if error == "access_denied" { throw RemoteCancelled() }
            throw MicrosoftAuthError(invalidGrant: false, message: "Microsoft refused the sign-in: \(Self.firstLine(value("error_description")) ?? error)")
        }
        guard let code = value("code") else {
            throw MicrosoftAuthError(invalidGrant: false, message: "Microsoft sent no sign-in code")
        }
        return try await auth.exchange(code: code, pkce: pkce, redirect: redirect)
    }

    static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// What the browser shows when it comes back.
    static func returnPage(_ url: URL, matched: Bool) -> SignInReturnServer.Page {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let error = items.first { $0.name == "error" }?.value
        if matched, error == "access_denied" {
            return .init(title: "Basil was not allowed", message: "You chose not to allow Basil. You can close this tab.")
        }
        if matched, let error {
            let detail = firstLine(items.first { $0.name == "error_description" }?.value) ?? error
            return .init(title: "Microsoft did not sign in", message: "Microsoft said: \(detail). You can close this tab and try again in Basil.")
        }
        if matched {
            return .init(title: "Signed in to OneDrive", message: "Basil is now authorised. You can close this tab and go back to Basil.")
        }
        return .init(title: "This sign-in has ended",
                     message: "Basil is no longer waiting for it. If you are not connected yet, connect again in Basil.")
    }

    /// Removes the account's sign-in from the Keychain, unless another saved connection uses the
    /// same account. Microsoft has no call to revoke it: Basil's access ends when the user
    /// removes Basil from the account's app permissions.
    public func forget(_ target: RemoteTarget, remaining: [RemoteTarget]) async {
        let account = target.host.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty,
              !remaining.contains(where: { $0.service == .oneDrive && $0.host == account }) else { return }
        secrets.remove(for: Self.keychainKey(account))
        secrets.remove(for: Self.scopesKey(account))
    }
}
