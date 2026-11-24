import Darwin
import Foundation
import Synchronization

/// A question git or ssh asks while it runs: a password, a user name, or a yes/no question
/// (ssh: an unknown host key).
public struct GitPrompt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case secret, text, yesNo }
    public let text: String
    public let kind: Kind

    public init(text: String) {
        self.text = text
        let lower = text.lowercased()
        kind = lower.contains("(yes/no") ? .yesNo : (lower.hasPrefix("username") ? .text : .secret)
    }
}

/// The UI's side of a login: answers a prompt (nil cancels), and hears whether the git run
/// that asked worked, so a secret can be remembered only once it did.
public protocol GitLogin: Sendable {
    /// `attempt` counts the same prompt within one run from 1: a second ask means git refused
    /// the first answer.
    func answer(_ prompt: GitPrompt, attempt: Int) async -> String?
    func finished(succeeded: Bool) async
}

/// GIT_ASKPASS and SSH_ASKPASS through Basil's own executable: git (or ssh) starts Basil with
/// the prompt as its argument and BASIL_GIT_ASKPASS_SOCKET set; that copy of Basil never opens
/// a window, it hands the prompt to the running app over a Unix socket in a private folder
/// (mode 700, with a random token) and prints the answer on stdout for git. Nothing secret is
/// on any command line. Protocol, one connection per prompt: the client sends the token and the
/// prompt in Base64, one line each; the app answers "OK <Base64 answer>" or "NO".
public enum GitAskPass {
    static let socketVariable = "BASIL_GIT_ASKPASS_SOCKET"
    static let tokenVariable = "BASIL_GIT_ASKPASS_TOKEN"

    /// Call first thing in main: when this process was started as git's askpass program it
    /// answers and exits, else it returns.
    public static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env[socketVariable], let token = env[tokenVariable] else { return }
        let prompt = CommandLine.arguments.dropFirst().first ?? "Password:"
        guard let answer = ask(prompt, socket: socket, token: token) else { exit(1) }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        exit(0)
    }

    static func ask(_ prompt: String, socket path: String, token: String) -> String? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard var address = unixAddress(path) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = token + "\n" + Data(prompt.utf8).base64EncodedString() + "\n"
        guard writeAll(fd, Data(request.utf8)) else { return nil }
        guard let line = readLine(fd), line.hasPrefix("OK "),
              let data = Data(base64Encoded: String(line.dropFirst(3))) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// One line (without the newline), at most 64 KB.
    static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 65536 {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}

/// The app's end: listens while one git run may ask, and answers through a `GitLogin`.
final class GitAskPassServer: Sendable {
    let folder: String
    let socketPath: String
    let token: String
    private let listener: Int32
    private let login: any GitLogin
    private let attempts = Mutex<[String: Int]>([:])

    init(login: any GitLogin) throws {
        self.login = login
        var template = Array((NSTemporaryDirectory() + "basil-askpass-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EACCES) }
        folder = String(cString: made)
        chmod(folder, 0o700)
        socketPath = folder + "/s"
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = GitAskPass.unixAddress(socketPath) else { if fd >= 0 { Darwin.close(fd) }; throw POSIXError(.EMFILE) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(socketPath, 0o600)
        listener = fd
        let server = self
        GitProcess.thread { server.acceptLoop() }
    }

    /// The variables git and ssh need to ask through Basil.
    func environment(executable: String) -> [String: String] {
        ["GIT_ASKPASS": executable, "SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force",
         GitAskPass.socketVariable: socketPath, GitAskPass.tokenVariable: token]
    }

    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
        rmdir(folder)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let server = self
            GitProcess.thread { server.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let token = GitAskPass.readLine(fd), token == self.token,
              let encoded = GitAskPass.readLine(fd), let data = Data(base64Encoded: encoded) else { return }
        let prompt = GitPrompt(text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        let attempt = attempts.withLock { counts in
            counts[prompt.text, default: 0] += 1
            return counts[prompt.text]!
        }
        let answer = Mutex<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        let login = login
        Task {
            let value = await login.answer(prompt, attempt: attempt)
            answer.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        let reply = answer.withLock { $0 }.map { "OK " + Data($0.utf8).base64EncodedString() + "\n" } ?? "NO\n"
        _ = GitAskPass.writeAll(fd, Data(reply.utf8))
    }
}

extension GitService {
    /// Runs git with logins asked through `login` (when an askpass program is set). Git's own
    /// credential helper (osxkeychain) and ssh-agent are still asked first, by git and ssh.
    func outputWithLogin(_ arguments: [String], in directory: String, login: (any GitLogin)?,
                         input: Data? = nil) async throws -> GitProcess.Output {
        guard let login, let askPassExecutable else { return try await output(arguments, in: directory, input: input) }
        let server = try GitAskPassServer(login: login)
        defer { server.close() }
        let output = try await output(arguments, in: directory, input: input,
                                      environment: server.environment(executable: askPassExecutable))
        await login.finished(succeeded: output.succeeded)
        return output
    }
}
