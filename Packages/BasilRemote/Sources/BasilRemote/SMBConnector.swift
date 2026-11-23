import BasilCore
import BasilVFS
import CNetFSShares
import Darwin
import Foundation
import NetFS

extension ProviderID {
    public static let smb = ProviderID("smb")
}

/// Connects to SMB servers (Windows shares, Samba, NAS boxes, Macs) through macOS's own SMB
/// client. One connection is one server and user: its top folder lists the server's shares,
/// and each share is mounted in /Volumes (like Finder's Connect to Server) the first time it
/// is used. A share that is already mounted is used as it is. Disconnect unmounts only the
/// shares Basil mounted. Files are read and written through the mount with the local code.
public struct SMBConnector: RemoteConnector {
    public init() {}

    public var service: ProviderID { .smb }
    public var displayName: String { "SMB" }
    public var defaultPort: Int { 445 }
    public var logins: [RemoteLogin] { [.password] }
    public var hostPlaceholder: String { "Name or address, such as nas.local" }
    public var userPlaceholder: String { "Empty: guest" }
    public var pathPlaceholder: String? { "Share and folder, such as /Media/Photos (empty: the list of shares)" }
    public var schemeAliases: [String] { ["cifs"] }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let endpoint = SMBEndpoint(host: target.host, port: target.port == defaultPort ? nil : target.port,
                                   user: target.user?.trimmingCharacters(in: .whitespaces) ?? "")
        var password: String?
        var asked: (SecretRequest, SecretAnswer)?
        if endpoint.isGuest {
            do {
                _ = try await SMBClient.shares(endpoint, password: nil)
            } catch let error as SMBError where error.code == EAUTH {
                throw VFSError.failed("\(endpoint.hostAndPort) does not let guests in. Edit the connection and fill in User.")
            }
        } else if SMBClient.hasSession(endpoint),
                  (try? await SMBClient.shares(endpoint, password: nil)) != nil {
            // A share of the server is mounted for this user already: macOS has a logged-in
            // session and uses it for any password, so none is asked (or saved unchecked).
        } else {
            var tries = 0
            while true {
                let request = SecretRequest(kind: .password, account: endpoint.account, retry: tries > 0,
                                            keychainKey: "\(service.rawValue):\(endpoint.account)")
                guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
                do {
                    _ = try await SMBClient.shares(endpoint, password: answer.secret)
                    password = answer.secret
                    asked = (request, answer)
                    break
                } catch let error as SMBError where error.code == EAUTH {
                    tries += 1
                    if tries == 3 { throw VFSError.failed("\(endpoint.hostAndPort) refused the user name or password") }
                }
            }
        }
        let provider = SMBProvider(endpoint: endpoint, password: password)
        let start = VFSPath(location: provider.location, path: target.path ?? "/")
        if !start.isRoot {
            // Mounts the share and checks the folder is there.
            do {
                let item = try await provider.item(at: start)
                guard item.isDirectoryLike else { throw VFSError.notADirectory(start) }
            } catch {
                await provider.disconnect()
                throw error
            }
        }
        if let (request, answer) = asked { await prompts.secretWorked(request, answer) }
        return (provider, start)
    }
}

/// A server and the user logging in to it.
struct SMBEndpoint: Sendable, Equatable {
    var host: String
    /// nil for the usual port 445.
    var port: Int?
    /// Empty: a guest login.
    var user: String

    var isGuest: Bool { user.isEmpty }
    var hostAndPort: String { port.map { "\(host):\($0)" } ?? host }
    /// "erion@nas.local", or "nas.local" for a guest.
    var account: String { isGuest ? hostAndPort : "\(user)@\(hostAndPort)" }

    /// smb://user:password@host:port/share, every part percent-encoded.
    func url(share: String? = nil, password: String? = nil) -> URL {
        var text = "smb://"
        if !isGuest {
            text += Self.encode(user)
            if let password { text += ":" + Self.encode(password) }
            text += "@"
        }
        text += host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port { text += ":\(port)" }
        if let share { text += "/" + Self.encode(share) }
        return URL(string: text)!
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: unreserved) ?? part
    }
}

/// A failure of macOS's SMB client, with its errno value.
struct SMBError: Error, LocalizedError, Sendable {
    var code: Int32
    var message: String
    var errorDescription: String? { message }
}

/// The blocking NetFS calls, run on their own queue (never on the cooperative pool).
enum SMBClient {
    static let queue = DispatchQueue(label: "basil.smb", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// The disk shares of a server, hidden ones (ending in "$") left out. Logging in this way
    /// also checks the password.
    static func shares(_ endpoint: SMBEndpoint, password: String?) async throws -> [String] {
        try await run {
            var result: Unmanaged<CFDictionary>?
            let status = BasilSMBListShares(endpoint.url(password: password) as CFURL, endpoint.isGuest, &result)
            let found = result?.takeRetainedValue() as? [String: Any]
            if status == ENETFSNOSHARESAVAIL { return [] }
            guard status == 0 else { throw error(status, endpoint: endpoint, share: nil) }
            return (found ?? [:]).compactMap { name, value in
                let info = value as? [String: Any] ?? [:]
                if name.hasSuffix("$") || info[kNetFSIsHiddenKey as String] as? Bool == true
                    || info[kNetFSPrinterShareKey as String] as? Bool == true { return nil }
                if let type = info["NetShareTypeStr"] as? String, type != "Disk" { return nil }
                return name
            }
        }
    }

    /// Mounts a share in /Volumes and returns the mount point. A share mounted already fails
    /// with EEXIST; callers look for it with `mountPoint(of:on:)` first.
    static func mount(_ share: String, endpoint: SMBEndpoint, password: String?) async throws -> String {
        try await run {
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionNoUI
            if endpoint.isGuest { open[kNetFSUseGuestKey] = true }
            var points: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(endpoint.url(share: share) as CFURL, nil,
                                           endpoint.isGuest ? nil : endpoint.user as CFString,
                                           password as CFString?, open, NSMutableDictionary(), &points)
            let list = points?.takeRetainedValue() as? [String]
            guard status == 0, let point = list?.first else {
                throw error(status == 0 ? EIO : status, endpoint: endpoint, share: share)
            }
            return point
        }
    }

    /// An SMB mount as its from-name says: "//user@host/share", "//GUEST:@host/share" or
    /// "//host/share", percent-encoded.
    struct MountedShare {
        var user: String?
        var host: String
        var share: String
        var path: String
    }

    static func mountedShares() -> [MountedShare] {
        mounts().compactMap { mount in
            guard mount.type == "smbfs", mount.from.hasPrefix("//") else { return nil }
            let rest = mount.from.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = rest[..<slash]
            var user: String?
            if let at = authority.lastIndex(of: "@") {
                let login = authority[..<at]
                user = String(login.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? login)
                user = user?.removingPercentEncoding ?? user
                authority = authority[authority.index(after: at)...]
            }
            var host = String(authority)
            if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex)..<close])
            } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
                host = String(host[..<colon])
            }
            let share = String(rest[rest.index(after: slash)...])
            return MountedShare(user: user, host: host, share: share.removingPercentEncoding ?? share, path: mount.on)
        }
    }

    /// Where a share of the server is mounted now (by Basil, Finder or anyone), or nil.
    static func mountPoint(of share: String, on endpoint: SMBEndpoint) -> String? {
        mountedShares().first {
            $0.host.caseInsensitiveCompare(endpoint.host) == .orderedSame
                && $0.share.caseInsensitiveCompare(share) == .orderedSame
        }?.path
    }

    /// Whether this user has a share of the server mounted, so macOS is logged in to it.
    static func hasSession(_ endpoint: SMBEndpoint) -> Bool {
        mountedShares().contains {
            $0.host.caseInsensitiveCompare(endpoint.host) == .orderedSame
                && $0.user?.caseInsensitiveCompare(endpoint.user) == .orderedSame
        }
    }

    /// Whether `path` is still the mount point of an SMB share.
    static func isMounted(_ path: String) -> Bool {
        var info = Darwin.statfs()
        guard statfs(path, &info) == 0 else { return false }
        return string(info.f_mntonname) == path && string(info.f_fstypename) == "smbfs"
    }

    /// Unmounts, waiting a little while something still has files open there.
    static func unmount(_ path: String) async {
        for attempt in 0..<10 {
            let result = try? await run { () -> Int32 in Darwin.unmount(path, 0) == 0 ? 0 : errno }
            guard result == EBUSY else { return }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(300)) }
        }
    }

    static func mounts() -> [(from: String, on: String, type: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 8)
        let found = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard found > 0 else { return [] }
        return buffer.prefix(Int(found)).map {
            (string($0.f_mntfromname), string($0.f_mntonname), string($0.f_fstypename))
        }
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func error(_ status: Int32, endpoint: SMBEndpoint, share: String?) -> SMBError {
        let server = endpoint.hostAndPort
        let message: String = switch status {
        case BasilSMBPluginMissing: "macOS's SMB client is missing (/System/Library/Filesystems/NetFSPlugins/smb.bundle)"
        case EAUTH: "\(server) refused the user name or password"
        case ENOENT where share != nil: "\(server) has no share named \(share!)"
        case EACCES, EPERM: share.map { "No permission for the share \($0) on \(server)" } ?? "No permission on \(server)"
        case ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ECONNREFUSED, ENOENT:
            "Could not reach \(server) (\(String(cString: strerror(status))))"
        // The SMB plugin's answer when nothing listens there (seen while Samba was starting).
        case -1: "Could not reach \(server) (no SMB server answered)"
        case ENETFSACCOUNTRESTRICTED: "\(server) does not let \(endpoint.user) log in now (the account is restricted)"
        case ENETFSPWDNEEDSCHANGE: "\(server) wants the password of \(endpoint.user) changed first"
        case ENETFSNOAUTHMECHSUPP: "\(server) offers no login method macOS can use"
        case ENETFSNOPROTOVERSSUPP: "\(server) speaks no SMB version macOS can use"
        default:
            status > 0 ? "\(server): \(String(cString: strerror(status)))" : "\(server): SMB error \(status)"
        }
        return SMBError(code: status, message: message)
    }
}
