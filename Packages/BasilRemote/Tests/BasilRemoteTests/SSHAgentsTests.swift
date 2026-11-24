import Darwin
import Foundation
import Testing
@testable import BasilRemote

@Suite struct SSHAgentsTests {
    /// A listening Unix socket at a short path (socket paths are limited to 104 bytes), and a
    /// fake home where known agent paths are links to it.
    final class Box {
        let home: URL
        let socket: String
        private var fd: Int32 = -1

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("basil-agents-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            socket = "/tmp/basil-agent-\(UUID().uuidString.prefix(8)).sock"
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = socket.utf8CString.withUnsafeBytes { memcpy(raw.baseAddress!, $0.baseAddress!, $0.count) }
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(ok == 0)
        }

        func link(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: socket)
        }

        deinit {
            close(fd)
            unlink(socket)
            try? FileManager.default.removeItem(at: home)
        }
    }

    @Test func knownAgentsAreFoundAfterSSHAuthSock() throws {
        let box = try Box()
        try box.link("Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
        try box.link("Library/Group Containers/group.strongbox.mac.mcguill/agent.sock")
        // A plain file is not an agent.
        try Data().write(to: box.home.appendingPathComponent(".bitwarden-ssh-agent.sock"))
        let agents = SSHAgents.resolve(identityAgent: nil, home: box.home.path, environment: ["SSH_AUTH_SOCK": "/nonexistent"])
        // Both links lead to the same socket: listed once, under the first name.
        #expect(agents.map(\.name) == ["1Password"])
        let env = SSHAgents.resolve(identityAgent: nil, home: box.home.path, environment: ["SSH_AUTH_SOCK": box.socket])
        // SSH_AUTH_SOCK set to a known agent is named after it, and that agent is not tried twice.
        #expect(env.map(\.name) == ["1Password"])
    }

    @Test func strongboxGroupContainerIsSearched() throws {
        let box = try Box()
        try box.link("Library/Group Containers/ABC.group.strongbox.mac/agent.sock")
        let agents = SSHAgents.resolve(identityAgent: nil, home: box.home.path, environment: [:])
        #expect(agents.map(\.name) == ["Strongbox"])
    }

    @Test func identityAgentWins() {
        let home = "/Users/a"
        #expect(SSHAgents.resolve(identityAgent: "none", home: home, environment: ["SSH_AUTH_SOCK": "/s"]).isEmpty)
        #expect(SSHAgents.resolve(identityAgent: "SSH_AUTH_SOCK", home: home, environment: ["SSH_AUTH_SOCK": "/s"])
            == [SSHAgent(name: "ssh-agent", socket: "/s")])
        #expect(SSHAgents.resolve(identityAgent: "$MY_SOCK", home: home, environment: ["MY_SOCK": "/m"]).map(\.socket) == ["/m"])
        let op = SSHAgents.resolve(identityAgent: "\"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\"",
                                   home: home, environment: [:])
        #expect(op == [SSHAgent(name: "1Password", socket: "/Users/a/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")])
    }
}
