import BasilCore
import BasilVFS
import Foundation
@preconcurrency import SwiftyDropbox

/// Connects to Dropbox accounts. Signing in happens on dropbox.com in the browser (OAuth 2 with
/// PKCE, see `DropboxAuth`); Basil never sees the password. A saved connection holds the
/// account's ID in `host` and its email address in `user` once it signed in, so several
/// accounts can be saved. The refresh token is kept in `secrets` (the Keychain) as
/// "dropbox:<account id>"; deleting the last saved connection of an account revokes it.
public struct DropboxConnector: RemoteConnector {
    let auth: DropboxAuth
    let secrets: any SecretStore

    /// `appKey`: from the Dropbox App Console (the app's Info.plist has it, set at build time).
    public init(appKey: String, secrets: any SecretStore, hosts: DropboxHosts = .dropbox) {
        // The SDK checks values with precondition (a crash in a release build) when a name or
        // answer does not match its patterns; Dropbox checks requests itself.
        Self.relaxValidation
        auth = DropboxAuth(appKey: appKey, hosts: hosts, session: URLSession(configuration: .ephemeral))
        self.secrets = secrets
    }

    private static let relaxValidation: Void = {
        setAssertFunc { _, _ in }
    }()

    public var service: ProviderID { .dropbox }
    public var displayName: String { "Dropbox" }
    public var defaultPort: Int { 443 }
    public var logins: [RemoteLogin] { [.automatic] }
    public var automaticLoginTitle: String { "Dropbox website" }
    public var usesServerAddress: Bool { false }
    public var loginNote: String? {
        "Connecting opens dropbox.com in your browser, where you sign in and allow Basil. Basil never sees your Dropbox password; its sign-in is kept in the Keychain."
    }

    static func keychainKey(_ accountID: String) -> String { "dropbox:\(accountID)" }
    /// The scopes the stored sign-in was granted, space-separated.
    static func scopesKey(_ accountID: String) -> String { "dropbox:\(accountID):scopes" }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let saved = target.host.trimmingCharacters(in: .whitespaces)
        var token: DropboxToken?
        // A sign-in from before Basil asked for more permissions (shared links) is replaced by a
        // new one, so Dropbox asks the user to allow them.
        if !saved.isEmpty, let refresh = secrets.secret(for: Self.keychainKey(saved)),
           DropboxScopes.covered(by: secrets.secret(for: Self.scopesKey(saved))) {
            do {
                let fresh = try await auth.refresh(refresh)
                token = DropboxToken(accessToken: fresh.accessToken, refreshToken: refresh, expires: fresh.expires,
                                     accountID: saved)
            } catch let error as DropboxAuthError where error.invalidGrant {
                // Access was removed on dropbox.com: sign in again.
                secrets.remove(for: Self.keychainKey(saved))
            }
        }
        let signedIn: DropboxToken
        if let token {
            signedIn = token
        } else {
            signedIn = try await signIn(prompts: prompts, account: target.user)
            secrets.save(signedIn.refreshToken, for: Self.keychainKey(signedIn.accountID))
            // Dropbox answers with the scopes it granted; without them, the ones asked for.
            let granted = signedIn.scopes.map { $0.sorted() } ?? DropboxScopes.all
            secrets.save(granted.joined(separator: " "), for: Self.scopesKey(signedIn.accountID))
        }
        let tokens = DropboxTokens(auth: auth, token: signedIn)
        let client = DropboxClient(transportClient: DropboxTransportClientImpl(
            accessTokenProvider: tokens, baseHosts: auth.hosts.baseHosts, userAgent: "Basil",
            selectUser: nil))
        let account: Users.FullAccount
        switch await client.users.getCurrentAccount().responseResult() {
        case .success(let value): account = value
        case .failure(let error):
            throw DropboxFailure(error).vfsError("Reading the Dropbox account", VFSPath(location: .local, path: "/"),
                                                 to: nil, email: target.user ?? "this account")
        }
        var updated = target
        updated.host = account.accountId
        updated.user = account.email
        updated.port = nil
        updated.authentication = .automatic
        let provider = DropboxProvider(client: client, tokens: tokens, auth: auth, email: account.email,
                                       displayName: account.name.displayName,
                                       signedInTarget: updated == target ? nil : updated)
        var start = target.path?.trimmingCharacters(in: .whitespaces) ?? ""
        if !start.hasPrefix("/") { start = "/" + start }
        return (provider, VFSPath(location: provider.location, path: start))
    }

    /// Signs in in the browser: opens the authorization page through `prompts` and waits for
    /// the redirect back to Basil, or for the user to give up.
    func signIn(prompts: any RemotePrompts, account: String?) async throws -> DropboxToken {
        let pkce = DropboxPKCE()
        let state = DropboxPKCE.state()
        let request = BrowserSignIn(service: displayName, url: auth.authorizationURL(pkce: pkce, state: state),
                                    account: account)
        enum Outcome: Sendable { case redirect(URL), cancelled, failed(String) }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .redirect(try await DropboxRedirects.wait(for: state)) } catch is RemoteCancelled {
                    return .cancelled
                } catch {
                    return .cancelled
                }
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
            throw DropboxAuthError(invalidGrant: false,
                                   message: "Dropbox refused the sign-in: \(value("error_description") ?? error)")
        }
        guard let code = value("code") else {
            throw DropboxAuthError(invalidGrant: false, message: "Dropbox sent no sign-in code")
        }
        return try await auth.exchange(code: code, pkce: pkce)
    }

    /// Revokes the account's sign-in and removes it from the Keychain, unless another saved
    /// connection uses the same account.
    public func forget(_ target: RemoteTarget, remaining: [RemoteTarget]) async {
        let account = target.host.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty,
              !remaining.contains(where: { $0.service == .dropbox && $0.host == account }) else { return }
        let key = Self.keychainKey(account)
        guard let refresh = secrets.secret(for: key) else { return }
        secrets.remove(for: key)
        secrets.remove(for: Self.scopesKey(account))
        if let fresh = try? await auth.refresh(refresh) {
            try? await auth.revoke(accessToken: fresh.accessToken)
        }
    }
}
