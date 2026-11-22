import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilRemote

/// macOS's own OpenSSH sshd, run as the test user on a free port of 127.0.0.1 with throwaway keys
/// in a temporary folder, plus an ssh-agent holding one more key. Started once for the whole run
/// and stopped when the test process exits. The server serves this Mac's file system, so tests
/// check results with FileManager.
final class TestServer: Sendable {
    static let shared: TestServer? = try? TestServer()

    let folder: URL
    let port: Int
    let hostKey: URL
    /// Plain ed25519 key.
    let plainKey: String
    /// ed25519 key encrypted with `passphrase`.
    let secretKey: String
    let passphrase = "open sesame"
    /// Only in the agent.
    let agentSocket: String
    /// The fake home folder the connector reads ~/.ssh/config from.
    let home: URL

    private static let children = Mutex<[pid_t]>([])
    private static let folders = Mutex<[String]>([])

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-sshd-\(UUID().uuidString.prefix(8))")
        self.folder = folder
        home = folder.appendingPathComponent("home")
        Self.folders.withLock { $0.append(folder.path) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        hostKey = folder.appendingPathComponent("host_ed25519")
        plainKey = folder.appendingPathComponent("plain").path
        secretKey = folder.appendingPathComponent("secret").path
        let agentKey = folder.appendingPathComponent("agent").path
        agentSocket = folder.appendingPathComponent("agent.sock").path
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", plainKey])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-f", secretKey])
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-N", "", "-f", agentKey])
        let authorized = try [plainKey, secretKey, agentKey].map { try String(contentsOfFile: $0 + ".pub", encoding: .utf8) }.joined()
        try authorized.write(to: folder.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        port = Self.freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(folder.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        MaxStartups 200
        MaxAuthTries 20
        PidFile \(folder.path)/sshd.pid
        PerSourcePenalties no
        Subsystem sftp internal-sftp
        """
        try config.write(to: folder.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
        try Self.start("/usr/sbin/sshd", ["-D", "-e", "-f", folder.appendingPathComponent("sshd_config").path],
                       log: folder.appendingPathComponent("sshd.log"))
        try Self.start("/usr/bin/ssh-agent", ["-D", "-a", agentSocket], log: folder.appendingPathComponent("agent.log"))
        try Self.waitFor { FileManager.default.fileExists(atPath: self.agentSocket) }
        try Self.run("/usr/bin/ssh-add", ["-q", agentKey], environment: ["SSH_AUTH_SOCK": agentSocket])
        let port = port
        try Self.waitFor { (try? SSHConnection.connectSocket(host: "127.0.0.1", port: port, timeout: 200)).map { close($0); return true } ?? false }
    }

    /// The server's host key as an SSH blob (what libssh2 reports).
    var hostKeyBlob: Data {
        let line = (try? String(contentsOfFile: hostKey.path + ".pub", encoding: .utf8)) ?? ""
        return Data(base64Encoded: String(line.split(separator: " ")[1])) ?? Data()
    }

    /// A connector that reads this server's fake home and the given known_hosts file.
    func connector(knownHosts: URL, agent: Bool = false) -> SFTPConnector {
        SFTPConnector(home: home, knownHostsFile: knownHosts, agentSocket: agent ? agentSocket : folder.appendingPathComponent("no-agent").path,
                      defaultKeys: false)
    }

    func target(_ auth: RemoteTarget.Authentication = .keyFile(""), path: String? = nil) -> RemoteTarget {
        var auth = auth
        if case .keyFile(let p) = auth, p.isEmpty { auth = .keyFile(plainKey) }
        return RemoteTarget(service: .sftp, host: "127.0.0.1", port: port, user: NSUserName(), path: path, authentication: auth)
    }

    // MARK: Processes

    static func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VFSError.failed("\(tool) failed") }
    }

    static func start(_ tool: String, _ arguments: [String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let first = children.withLock { list in
            list.append(process.processIdentifier)
            return list.count == 1
        }
        if first {
            atexit {
                for pid in TestServer.children.withLock({ $0 }) { kill(pid, SIGTERM) }
                for folder in TestServer.folders.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: folder) }
            }
        }
    }

    static func waitFor(_ condition: () -> Bool) throws {
        for _ in 0..<100 {
            if condition() { return }
            usleep(50_000)
        }
        throw VFSError.failed("Test server did not start")
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Scripted answers for connection questions.
final class TestPrompts: RemotePrompts {
    struct State {
        var hostKeyAnswer: HostKeyAnswer = .trustAndRemember
        var secrets: [String?] = []
        var hostKeyQuestions: [HostKeyQuestion] = []
        var secretRequests: [SecretRequest] = []
        var worked: [SecretRequest] = []
        var notes: [String] = []
    }

    let state: Mutex<State>

    init(hostKey: HostKeyAnswer = .trustAndRemember, secrets: [String?] = []) {
        state = Mutex(State(hostKeyAnswer: hostKey, secrets: secrets))
    }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer {
        state.withLock { $0.hostKeyQuestions.append(question); return $0.hostKeyAnswer }
    }

    func secret(_ request: SecretRequest) async -> SecretAnswer? {
        state.withLock { s in
            s.secretRequests.append(request)
            guard !s.secrets.isEmpty, let next = s.secrets.removeFirst() else { return nil }
            return SecretAnswer(secret: next, remember: false)
        }
    }

    func secretWorked(_ request: SecretRequest, _ answer: SecretAnswer) async {
        state.withLock { $0.worked.append(request) }
    }

    func note(_ message: String) async { state.withLock { $0.notes.append(message) } }
}

/// A fresh known_hosts file and a remote work folder (a local temp folder, served by the server).
final class RemoteSandbox: Sendable {
    let folder: URL
    let knownHosts: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        knownHosts = folder.appendingPathComponent("known_hosts")
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The sandbox's work folder; the server sees the same path.
    var path: String { folder.appendingPathComponent("work").path }

    func prepare() throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Trusts the test server's key, so connecting does not ask.
    func trustServer(_ server: TestServer) throws {
        var known = KnownHosts(file: knownHosts)
        try known.remember(host: KnownHosts.hostName("127.0.0.1", port: server.port), key: server.hostKeyBlob)
    }
}
