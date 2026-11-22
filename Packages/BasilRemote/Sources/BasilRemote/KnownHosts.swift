import CryptoKit
import Foundation

/// OpenSSH's known_hosts file (sshd(8) "SSH_KNOWN_HOSTS FILE FORMAT"): host patterns (plain,
/// wildcards, negations, "[host]:port", hashed "|1|salt|hash"), a key type and the key. Lines with
/// "@revoked" refuse that key; "@cert-authority" lines are skipped (Basil does not check
/// certificates). The file is only ever added to or has single lines replaced, so comments and
/// everything else in it stay as they are.
public struct KnownHosts: Sendable {
    public enum Result: Equatable, Sendable {
        case known
        /// The host has a different key of this type.
        case changed
        case unknown
        /// The key is listed as @revoked.
        case revoked
    }

    struct Line: Sendable {
        var marker: String?
        var patterns: [String]
        var keyType: String
        var key: Data
    }

    public let file: URL
    var lines: [Line]

    public init(file: URL) {
        self.file = file
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        lines = text.split(whereSeparator: \.isNewline).compactMap { Self.parse(String($0)) }
    }

    public static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    /// The name known_hosts uses: "host" on port 22, else "[host]:port".
    public static func hostName(_ host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Checks a server key (the SSH wire blob) for `host` (from `hostName`).
    public func check(host: String, key: Data) -> Result {
        let type = Self.keyType(of: key)
        var sameType = false
        for line in lines where Self.matches(host, line.patterns) {
            if line.marker == "@revoked" {
                if line.key == key { return .revoked }
                continue
            }
            guard line.marker == nil else { continue }
            if line.key == key { return .known }
            if line.keyType == type { sameType = true }
        }
        return sameType ? .changed : .unknown
    }

    /// Key types known for `host`, so the connection asks the server for one of those first.
    public func keyTypes(for host: String) -> [String] {
        var out: [String] = []
        for line in lines where line.marker == nil && Self.matches(host, line.patterns) && !out.contains(line.keyType) {
            out.append(line.keyType)
        }
        return out
    }

    /// Saves `key` for `host`: replaces the lines that name only this host with a key of the same
    /// type, or appends a line. Written through a temporary file and renamed into place.
    public mutating func remember(host: String, key: Data) throws {
        let type = Self.keyType(of: key)
        let entry = "\(host) \(type) \(key.base64EncodedString())"
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var out: [String] = []
        var replaced = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if let parsed = Self.parse(line), parsed.marker == nil, parsed.keyType == type,
               parsed.patterns.count == 1, Self.matches(host, parsed.patterns) {
                if !replaced { out.append(entry) }
                replaced = true
                continue
            }
            out.append(line)
        }
        while let last = out.last, last.isEmpty { out.removeLast() }
        if !replaced { out.append(entry) }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".known_hosts.basil-\(UUID().uuidString)")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o600
        try Data((out.joined(separator: "\n") + "\n").utf8).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        if rename(temporary.path, file.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        lines = (out.compactMap { Self.parse($0) })
    }

    // MARK: Parsing and matching

    static func parse(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var marker: String?
        if let first = fields.first, first.hasPrefix("@") {
            marker = first
            fields.removeFirst()
        }
        guard fields.count >= 3, let key = Data(base64Encoded: fields[2]) else { return nil }
        return Line(marker: marker, patterns: fields[0].split(separator: ",").map(String.init),
                    keyType: fields[1], key: key)
    }

    /// One pattern matches and no negated one does; hashed patterns compare HMAC-SHA1.
    static func matches(_ host: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("|1|") {
                if hashedMatches(host, pattern) { matched = true }
            } else if pattern.hasPrefix("!") {
                if SSHConfig.glob(String(pattern.dropFirst()), host) { return false }
            } else if SSHConfig.glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    static func hashedMatches(_ host: String, _ pattern: String) -> Bool {
        let parts = pattern.split(separator: "|", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "1",
              let salt = Data(base64Encoded: String(parts[1])), let hash = Data(base64Encoded: String(parts[2])) else { return false }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8), using: SymmetricKey(data: salt))
        return Data(mac) == hash
    }

    /// The key type named at the start of an SSH key blob ("ssh-ed25519").
    static func keyType(of key: Data) -> String {
        guard key.count >= 4 else { return "" }
        let bytes = [UInt8](key)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, 4 + length <= bytes.count else { return "" }
        return String(decoding: bytes[4..<(4 + length)], as: UTF8.self)
    }

    /// "SHA256:..." as ssh prints it (base64 without padding).
    public static func fingerprint(of key: Data) -> String {
        let digest = Data(SHA256.hash(data: key)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// "ED25519", "ECDSA", "RSA", "DSA" for questions.
    public static func displayType(of key: Data) -> String {
        let type = keyType(of: key)
        if type.contains("ed25519") { return "ED25519" }
        if type.contains("ecdsa") { return "ECDSA" }
        if type.contains("rsa") { return "RSA" }
        if type.contains("dss") { return "DSA" }
        return type
    }
}
