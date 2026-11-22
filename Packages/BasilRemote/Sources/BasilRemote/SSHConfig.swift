import Foundation

/// What ~/.ssh/config says about one host: the keys Basil uses. Like ssh, the first value found
/// for a key wins, except IdentityFile, which collects every value.
public struct SSHHostConfig: Equatable, Sendable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []
    public var identitiesOnly: Bool?
    /// Keys Basil does not support that apply to this host (ProxyJump, ProxyCommand, ...), as written.
    public var unsupported: [String] = []

    public init() {}
}

/// A reader for OpenSSH's client configuration (ssh_config(5)), limited to Host blocks and the
/// keys in `SSHHostConfig`. Include is followed; Match blocks are skipped and reported.
public struct SSHConfig: Sendable {
    struct Entry: Sendable {
        var key: String // lowercased
        var value: String
        var line: String
    }

    struct Block: Sendable {
        /// nil: the lines before the first Host (they apply to every host). Empty: a Match block.
        var patterns: [String]?
        var isMatch = false
        var entries: [Entry] = []
    }

    var blocks: [Block]

    /// Keys that change how the connection is made and that Basil cannot follow.
    static let unsupportedKeys: Set<String> = ["proxyjump", "proxycommand", "localforward", "remoteforward",
                                               "dynamicforward", "certificatefile"]

    public init(text: String, includeBase: URL? = nil) {
        blocks = []
        var current = Block(patterns: nil)
        Self.parse(text, includeBase: includeBase, depth: 0, blocks: &blocks, current: &current)
        blocks.append(current)
    }

    /// ~/.ssh/config, or an empty config when there is none.
    public static func user(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SSHConfig {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        let text = (try? String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8)) ?? ""
        return SSHConfig(text: text, includeBase: ssh)
    }

    /// The settings for `host` (the name as typed, before HostName).
    public func resolve(_ host: String, localUser: String = NSUserName(),
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> SSHHostConfig {
        var config = SSHHostConfig()
        var seen = Set<String>()
        var rawIdentities: [String] = []
        for block in blocks {
            if block.isMatch {
                if !config.unsupported.contains("Match") { config.unsupported.append("Match") }
                continue
            }
            if let patterns = block.patterns, !Self.matches(host, patterns) { continue }
            for entry in block.entries {
                if entry.key == "identityfile" { rawIdentities.append(entry.value); continue }
                if Self.unsupportedKeys.contains(entry.key) {
                    if !seen.contains(entry.key) { config.unsupported.append(entry.line) }
                    seen.insert(entry.key)
                    continue
                }
                guard seen.insert(entry.key).inserted else { continue }
                switch entry.key {
                case "hostname": config.hostName = entry.value
                case "user": config.user = entry.value
                case "port": config.port = Int(entry.value)
                case "identitiesonly": config.identitiesOnly = entry.value.lowercased() == "yes"
                default: break
                }
            }
        }
        let tokens = Tokens(host: config.hostName ?? host, alias: host, user: config.user ?? localUser,
                            port: config.port ?? 22, localUser: localUser, home: home)
        config.hostName = config.hostName.map { $0.replacingOccurrences(of: "%h", with: host) }
        config.identityFiles = rawIdentities.map { tokens.expand($0) }
        return config
    }

    /// Host aliases without wildcards, for suggestions.
    public var aliases: [String] {
        var out: [String] = []
        for block in blocks where !block.isMatch {
            for pattern in block.patterns ?? [] where !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?") {
                if !out.contains(pattern) { out.append(pattern) }
            }
        }
        return out
    }

    // MARK: Parsing

    private static func parse(_ text: String, includeBase: URL?, depth: Int, blocks: inout [Block], current: inout Block) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = split(line) else { continue }
            switch key {
            case "host":
                blocks.append(current)
                current = Block(patterns: words(value))
            case "match":
                blocks.append(current)
                current = Block(patterns: [], isMatch: true)
            case "include":
                guard depth < 8 else { continue }
                for file in words(value).flatMap({ includedFiles($0, base: includeBase) }) {
                    guard let included = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    parse(included, includeBase: includeBase, depth: depth + 1, blocks: &blocks, current: &current)
                }
            default:
                current.entries.append(Entry(key: key, value: unquote(value), line: line))
            }
        }
    }

    /// "Key value", "Key=value" or "Key = value". The key comes back lowercased.
    static func split(_ line: String) -> (String, String)? {
        guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = line[..<end].lowercased()
        var rest = line[end...].drop { $0 == " " || $0 == "\t" }
        if rest.hasPrefix("=") { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (key, value)
    }

    /// Whitespace-separated words; double quotes keep spaces.
    static func words(_ value: String) -> [String] {
        var out: [String] = []
        var word = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); continue }
            if !quoted, ch == " " || ch == "\t" {
                if !word.isEmpty { out.append(word); word = "" }
                continue
            }
            word.append(ch)
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    static func unquote(_ value: String) -> String {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }

    /// An Include argument: "~" expanded, relative names are in ~/.ssh, wildcards in the last part.
    static func includedFiles(_ pattern: String, base: URL?) -> [URL] {
        var path = pattern
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() }
        else if !path.hasPrefix("/"), let base { path = base.appendingPathComponent(path).path }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [url] }
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { glob(name, $0) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// A Host line matches when one pattern matches and no negated pattern does.
    static func matches(_ host: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), host) { return false }
            } else if glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    /// ssh's wildcard match: "*" any run, "?" one character, no case.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// %-tokens of IdentityFile (ssh_config TOKENS) and "~".
    struct Tokens {
        var host: String, alias: String, user: String, port: Int, localUser: String, home: String

        func expand(_ value: String) -> String {
            var out = ""
            var chars = value.makeIterator()
            while let ch = chars.next() {
                guard ch == "%" else { out.append(ch); continue }
                switch chars.next() {
                case "h": out += host
                case "n": out += alias
                case "r": out += user
                case "p": out += String(port)
                case "u": out += localUser
                case "d": out += home
                case "%": out += "%"
                case let other?: out += "%" + String(other)
                case nil: out += "%"
                }
            }
            if out == "~" { return home }
            if out.hasPrefix("~/") { return home + out.dropFirst() }
            return out
        }
    }
}
