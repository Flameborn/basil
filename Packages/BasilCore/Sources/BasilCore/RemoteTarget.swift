import Foundation

/// Where a remote connection goes: what a saved connection or a Quick Connect address holds.
/// Never holds secrets (those live in the Keychain).
public struct RemoteTarget: Codable, Hashable, Sendable {
    public enum Authentication: Codable, Hashable, Sendable {
        /// The service's usual order (SFTP: ssh-agent, key files, then a password).
        case automatic
        case password
        /// One private key file (a path, "~" allowed).
        case keyFile(String)
    }

    /// The connector's service ("sftp").
    public var service: ProviderID
    /// Host name, address or (SFTP) a Host alias from ~/.ssh/config.
    public var host: String
    /// nil: the service's default port (or the ssh config's).
    public var port: Int?
    /// nil: the ssh config's user, otherwise the local user name.
    public var user: String?
    /// Start folder; nil or empty: the server's home folder.
    public var path: String?
    public var authentication: Authentication

    public init(service: ProviderID, host: String, port: Int? = nil, user: String? = nil,
                path: String? = nil, authentication: Authentication = .automatic) {
        self.service = service
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.authentication = authentication
    }

    /// Reads "user@host:port/path", with an optional "sftp://" prefix. nil when there is no host.
    /// IPv6 addresses go in brackets ("[::1]:2222").
    public static func parse(_ text: String, defaultService: ProviderID) -> RemoteTarget? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var service = defaultService
        if let scheme = rest.range(of: "://") {
            service = ProviderID(rest[..<scheme.lowerBound].lowercased())
            rest = rest[scheme.upperBound...]
        }
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = rest[..<slash]
        }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at]).removingPercentEncoding ?? String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var host = rest
        var port: Int?
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            host = host[host.index(after: host.startIndex)..<close]
        } else if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            port = Int(host[host.index(after: colon)...])
            host = host[..<colon]
        }
        guard !host.isEmpty else { return nil }
        if user?.isEmpty == true { user = nil }
        return RemoteTarget(service: service, host: String(host), port: port, user: user,
                            path: path == "/" ? "/" : path)
    }
}

/// A connection kept in Settings (Cmd+K's list).
public struct SavedConnection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Shown in lists and menus; empty: the address.
    public var name: String
    public var target: RemoteTarget

    public init(id: UUID = UUID(), name: String, target: RemoteTarget) {
        self.id = id
        self.name = name
        self.target = target
    }

    /// The name, or "user@host:port" when it has none.
    public var title: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? target.address : name
    }
}

extension RemoteTarget {
    /// "user@host:port/path" without the service, as Quick Connect reads it.
    public var address: String {
        var text = user.map { "\($0)@" } ?? ""
        text += host.contains(":") ? "[\(host)]" : host
        if let port { text += ":\(port)" }
        if let path, !path.isEmpty { text += path.hasPrefix("/") ? path : "/" + path }
        return text
    }
}
