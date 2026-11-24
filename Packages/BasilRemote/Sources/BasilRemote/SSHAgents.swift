import Foundation

/// An SSH agent socket Basil can log in with: the system ssh-agent (SSH_AUTH_SOCK, which
/// KeePassXC also adds its keys to), or a password manager's own agent.
struct SSHAgent: Sendable, Hashable {
    /// "ssh-agent", "1Password", "Bitwarden", ...
    var name: String
    var socket: String
}

/// Finds agent sockets the way ssh would use them, plus the agents of password managers that
/// listen on their own sockets, so their keys work without editing ~/.ssh/config.
///
/// - `IdentityAgent` in ~/.ssh/config wins, like in ssh: "none" means no agent, "SSH_AUTH_SOCK"
///   the environment's agent, "$NAME" that environment variable, anything else a path (~ and %d
///   are expanded).
/// - Otherwise SSH_AUTH_SOCK first, then every known agent whose socket exists.
enum SSHAgents {
    /// Known password manager agents and where their sockets live, relative to the home folder.
    static let known: [(name: String, paths: [String])] = [
        ("1Password", ["Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock", ".1password/agent.sock"]),
        ("Bitwarden", ["Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock",
                       ".bitwarden-ssh-agent.sock"]),
        ("Secretive", ["Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"]),
        ("Strongbox", [".strongbox/agent.sock"]),
        ("GnuPG", [".gnupg/S.gpg-agent.ssh"]),
    ]

    static func resolve(identityAgent: String?, home: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [SSHAgent] {
        if let value = identityAgent {
            switch value {
            case let v where v.lowercased() == "none":
                return []
            case "SSH_AUTH_SOCK":
                return environment["SSH_AUTH_SOCK"].map { [SSHAgent(name: "ssh-agent", socket: $0)] } ?? []
            case let v where v.hasPrefix("$"):
                return environment[String(v.dropFirst())].map { [SSHAgent(name: "ssh-agent", socket: $0)] } ?? []
            default:
                let path = expand(value, home: home)
                return [SSHAgent(name: name(ofSocket: path, home: home) ?? "the agent in ~/.ssh/config", socket: path)]
            }
        }
        var agents: [SSHAgent] = []
        var seen = Set<String>()
        func add(_ name: String, _ path: String) {
            let real = (path as NSString).resolvingSymlinksInPath
            guard isSocket(path), seen.insert(real).inserted else { return }
            agents.append(SSHAgent(name: name, socket: path))
        }
        if let env = environment["SSH_AUTH_SOCK"], !env.isEmpty {
            add(name(ofSocket: env, home: home) ?? "ssh-agent", env)
        }
        for agent in known {
            for path in agent.paths { add(agent.name, (home as NSString).appendingPathComponent(path)) }
        }
        for path in strongboxSockets(home: home) { add("Strongbox", path) }
        return agents
    }

    /// Strongbox's socket lies in one of its group containers.
    static func strongboxSockets(home: String) -> [String] {
        let groups = (home as NSString).appendingPathComponent("Library/Group Containers")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: groups) else { return [] }
        return names.filter { $0.lowercased().contains("strongbox") }.map {
            ((groups as NSString).appendingPathComponent($0) as NSString).appendingPathComponent("agent.sock")
        }
    }

    /// Which known agent a socket path belongs to (also through links).
    static func name(ofSocket path: String, home: String) -> String? {
        let real = (path as NSString).resolvingSymlinksInPath
        for agent in known {
            for p in agent.paths {
                let candidate = (home as NSString).appendingPathComponent(p)
                if candidate == path || (candidate as NSString).resolvingSymlinksInPath == real { return agent.name }
            }
        }
        if path.lowercased().contains("strongbox") { return "Strongbox" }
        return nil
    }

    static func expand(_ value: String, home: String) -> String {
        var v = value
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        if v == "~" { return home }
        if v.hasPrefix("~/") { v = home + v.dropFirst() }
        return v.replacingOccurrences(of: "%d", with: home)
    }

    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFSOCK
    }
}
