import BasilCore
import BasilVFS
import CLibSSH2
import Darwin
import Foundation
import Synchronization

/// libssh2 is set up once per process.
enum LibSSH2 {
    static let ready: Bool = libssh2_init(0) == 0
}

/// Where a connection goes, after ~/.ssh/config was applied.
struct SSHEndpoint: Sendable, Hashable {
    /// The name the user gave (alias or host), for titles and known_hosts.
    var alias: String
    /// The host to connect to (HostName).
    var host: String
    var port: Int
    var user: String
    var identityFiles: [String]
    var identitiesOnly: Bool
    var authentication: RemoteTarget.Authentication
    /// ssh-agent socket; nil: SSH_AUTH_SOCK.
    var agentSocket: String?

    /// "[host]:port" or "host", as known_hosts writes it.
    var knownHostsName: String { KnownHosts.hostName(host, port: port) }
    var account: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}

/// How the last login worked, so a dropped connection logs in again without asking.
enum SSHLogin: Sendable {
    case none
    case agent(identity: Data)
    case key(path: String, passphrase: String?)
    case password(String)
    case keyboard(password: String?, answers: [String: String])
}

/// One SSH connection with its SFTP channel. Every libssh2 call runs on `queue` (libssh2 is not
/// thread safe per session and its calls block), never on the cooperative pool.
final class SSHConnection: @unchecked Sendable {
    let endpoint: SSHEndpoint
    let queue: DispatchQueue

    // Only touched on `queue`.
    private var socket: Int32 = -1
    private(set) var session: OpaquePointer?
    private(set) var sftp: OpaquePointer?
    /// Counts connections; handles from an older one are dead.
    private(set) var generation = 0
    private var keepalive: DispatchSourceTimer?
    /// Set once logged in: the host key accepted and how the login worked.
    private var acceptedKey: Data?
    private var login: SSHLogin = .none
    private var closed = false
    /// Answers for keyboard-interactive prompts while `userauth_keyboard_interactive` runs.
    fileprivate var keyboard: (([String]) -> [String]?)?

    static let connectTimeout: Int32 = 15_000
    static let ioTimeout: Int = 60_000

    init(endpoint: SSHEndpoint) {
        self.endpoint = endpoint
        queue = DispatchQueue(label: "basil.sftp.\(endpoint.account)", qos: .userInitiated)
    }

    deinit {
        keepalive?.cancel()
        if let sftp { libssh2_sftp_shutdown(sftp) }
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Basil closed the connection", "")
            libssh2_session_free(session)
        }
        if socket >= 0 { Darwin.close(socket) }
    }

    /// Runs `body` on the connection's queue.
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    // MARK: Connecting (each step on the queue; questions in between are async)

    /// TCP connect and SSH handshake. Returns the server's host key blob.
    func open() throws -> Data {
        dispatchPrecondition(condition: .onQueue(queue))
        guard LibSSH2.ready else { throw VFSError.failed("libssh2 could not be started") }
        tearDown()
        socket = try Self.connectSocket(host: endpoint.host, port: endpoint.port, timeout: Self.connectTimeout)
        let abstract = Unmanaged.passUnretained(self).toOpaque()
        guard let session = libssh2_session_init_ex(nil, nil, nil, abstract) else {
            throw VFSError.failed("Could not start an SSH session")
        }
        self.session = session
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Self.ioTimeout)
        libssh2_session_flag(session, LIBSSH2_FLAG_COMPRESS, 1)
        let preferred = Self.hostKeyMethods(knownTypes: KnownHosts(file: KnownHosts.userFile).keyTypes(for: endpoint.knownHostsName),
                                            session: session)
        if !preferred.isEmpty { libssh2_session_method_pref(session, LIBSSH2_METHOD_HOSTKEY, preferred) }
        let rc = libssh2_session_handshake(session, libssh2_socket_t(socket))
        guard rc == 0 else { throw sessionError(rc, "Could not start SSH with \(endpoint.host)") }
        var length = 0
        var type: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &length, &type), length > 0 else {
            throw VFSError.failed("\(endpoint.host) sent no host key")
        }
        return Data(bytes: key, count: length)
    }

    /// Login methods the server offers for the user ("publickey,password"). Empty when the server
    /// let the user in without any ("none" authentication).
    func authMethods() throws -> [String] {
        guard let session else { throw VFSError.failed("Not connected") }
        let user = endpoint.user
        let list = user.withCString { libssh2_userauth_list(session, $0, UInt32(user.utf8.count)) }
        if let list { return String(cString: list).split(separator: ",").map(String.init) }
        if libssh2_userauth_authenticated(session) != 0 { return [] }
        throw sessionError(libssh2_session_last_errno(session), "\(endpoint.host) did not answer the login")
    }

    var isAuthenticated: Bool {
        session.map { libssh2_userauth_authenticated($0) != 0 } ?? false
    }

    /// Tries every identity in the agent. Returns the identity that worked, or nil.
    func authenticateWithAgent() throws -> Data? {
        guard let session else { return nil }
        guard let agent = libssh2_agent_init(session) else { return nil }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }
        if let socket = endpoint.agentSocket { socket.withCString { libssh2_agent_set_identity_path(agent, $0) } }
        guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0 else { return nil }
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        while libssh2_agent_get_identity(agent, &identity, previous) == 0, let current = identity {
            let blob = Data(bytes: current.pointee.blob, count: current.pointee.blob_len)
            if libssh2_agent_userauth(agent, endpoint.user, current) == 0 { return blob }
            if !Self.isAuthRejection(libssh2_session_last_errno(session)) {
                throw sessionError(libssh2_session_last_errno(session), "Login with ssh-agent failed")
            }
            previous = current
        }
        return nil
    }

    /// Logs in with the agent identity that worked before (after a reconnect).
    private func authenticateWithAgent(identity: Data) throws -> Bool {
        guard let session, let agent = libssh2_agent_init(session) else { return false }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }
        if let socket = endpoint.agentSocket { socket.withCString { libssh2_agent_set_identity_path(agent, $0) } }
        guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0 else { return false }
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var current: UnsafeMutablePointer<libssh2_agent_publickey>?
        while libssh2_agent_get_identity(agent, &current, previous) == 0, let id = current {
            if Data(bytes: id.pointee.blob, count: id.pointee.blob_len) == identity {
                return libssh2_agent_userauth(agent, endpoint.user, id) == 0
            }
            previous = id
        }
        return false
    }

    enum KeyResult { case accepted, rejected, wrongPassphrase }

    func authenticate(keyFile: String, passphrase: String?) throws -> KeyResult {
        guard let session else { throw VFSError.failed("Not connected") }
        let user = endpoint.user
        let rc = libssh2_userauth_publickey_fromfile_ex(session, user, UInt32(user.utf8.count), nil, keyFile, passphrase)
        if rc == 0 { return .accepted }
        if rc == LIBSSH2_ERROR_FILE { return passphrase == nil && !KeyFiles.isEncrypted(keyFile) ? .rejected : .wrongPassphrase }
        if Self.isAuthRejection(rc) { return .rejected }
        throw sessionError(rc, "Login with \(keyFile) failed")
    }

    /// true: logged in; false: the password was refused.
    func authenticate(password: String) throws -> Bool {
        guard let session else { throw VFSError.failed("Not connected") }
        let user = endpoint.user
        let rc = libssh2_userauth_password_ex(session, user, UInt32(user.utf8.count),
                                              password, UInt32(password.utf8.count), nil)
        if rc == 0 { return true }
        if Self.isAuthRejection(rc) || rc == LIBSSH2_ERROR_PASSWORD_EXPIRED { return false }
        throw sessionError(rc, "Password login failed")
    }

    /// Keyboard-interactive: `answer` gets the prompts of each round and returns the replies
    /// (nil cancels). It runs on the queue and may block it while the user answers.
    func authenticateInteractively(_ answer: @escaping ([String]) -> [String]?) throws -> Bool {
        guard let session else { throw VFSError.failed("Not connected") }
        keyboard = answer
        defer { keyboard = nil }
        let user = endpoint.user
        let rc = libssh2_userauth_keyboard_interactive_ex(session, user, UInt32(user.utf8.count), keyboardCallback)
        if rc == 0 { return true }
        if Self.isAuthRejection(rc) { return false }
        throw sessionError(rc, "Login failed")
    }

    /// Opens the SFTP channel and starts keepalives. Records how the login worked.
    func finish(hostKey: Data, login: SSHLogin) throws {
        guard let session else { throw VFSError.failed("Not connected") }
        guard let sftp = libssh2_sftp_init(session) else {
            throw sessionError(libssh2_session_last_errno(session), "\(endpoint.host) did not start SFTP")
        }
        self.sftp = sftp
        acceptedKey = hostKey
        self.login = login
        generation += 1
        libssh2_keepalive_config(session, 1, 30)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            var next: Int32 = 0
            if libssh2_keepalive_send(session, &next) != 0 { self.tearDown() }
        }
        timer.resume()
        keepalive = timer
    }

    // MARK: Using the connection

    /// The live SFTP channel; logs in again (without asking) when the connection dropped.
    func channel() throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(queue))
        if closed { throw VFSError.failed("The connection to \(endpoint.host) was closed") }
        if let sftp { return sftp }
        try reconnect()
        guard let sftp else { throw VFSError.failed("Not connected to \(endpoint.host)") }
        return sftp
    }

    private func reconnect() throws {
        guard let accepted = acceptedKey else { throw VFSError.failed("Not connected to \(endpoint.host)") }
        let key = try open()
        guard key == accepted else {
            tearDown()
            throw VFSError.failed("The host key of \(endpoint.host) changed since Basil connected. Connect again to check it.")
        }
        let ok: Bool
        switch login {
        case .none: ok = try isAuthenticated || authMethods().isEmpty
        case .agent(let identity): ok = try authenticateWithAgent(identity: identity)
        case .key(let path, let passphrase): ok = try authenticate(keyFile: path, passphrase: passphrase) == .accepted
        case .password(let password): ok = try authenticate(password: password)
        case .keyboard(let password, let answers):
            ok = try authenticateInteractively { prompts in
                prompts.map { prompt in
                    answers[prompt] ?? (prompt.lowercased().contains("password") ? password ?? "" : "")
                }
            }
        }
        guard ok else {
            tearDown()
            throw VFSError.failed("Could not log in to \(endpoint.host) again. Connect again.")
        }
        try finish(hostKey: accepted, login: login)
    }

    /// Drops the connection; the next call reconnects. Handles of this generation are dead.
    func tearDown() {
        keepalive?.cancel()
        keepalive = nil
        if let sftp { libssh2_sftp_shutdown(sftp) }
        sftp = nil
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Basil closed the connection", "")
            libssh2_session_free(session)
        }
        session = nil
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
    }

    /// Closes for good (Disconnect).
    func close() {
        tearDown()
        closed = true
    }

    // MARK: Errors

    /// A libssh2 failure as a VFSError. SFTP status codes map to the usual errors; a broken
    /// connection is torn down so the next call reconnects.
    func error(_ rc: Int32, _ path: VFSPath, _ what: String) -> VFSError {
        if rc == LIBSSH2_ERROR_SFTP_PROTOCOL, let sftp {
            switch UInt(libssh2_sftp_last_error(sftp)) {
            case LIBSSH2_FX_NO_SUCH_FILE, LIBSSH2_FX_NO_SUCH_PATH: return .notFound(path)
            case LIBSSH2_FX_PERMISSION_DENIED, LIBSSH2_FX_WRITE_PROTECT: return .permissionDenied(path)
            case LIBSSH2_FX_FILE_ALREADY_EXISTS: return .alreadyExists(path)
            case LIBSSH2_FX_DIR_NOT_EMPTY: return .directoryNotEmpty(path)
            case LIBSSH2_FX_NOT_A_DIRECTORY: return .notADirectory(path)
            case LIBSSH2_FX_OP_UNSUPPORTED: return .unsupported(what)
            case LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM, LIBSSH2_FX_QUOTA_EXCEEDED:
                return .posix(code: ENOSPC, path: path)
            case let status: return .failed("\(what) failed on \(endpoint.host) (SFTP status \(status))")
            }
        }
        return sessionError(rc, "\(what) failed")
    }

    func sessionError(_ rc: Int32, _ what: String) -> VFSError {
        var message: String?
        if let session {
            var text: UnsafeMutablePointer<CChar>?
            var length: Int32 = 0
            libssh2_session_last_error(session, &text, &length, 0)
            if let text, length > 0 { message = String(cString: text) }
        }
        if Self.isConnectionLost(rc) { tearDown() }
        if rc == LIBSSH2_ERROR_TIMEOUT || rc == LIBSSH2_ERROR_SOCKET_TIMEOUT {
            return .failed("\(what): \(endpoint.host) did not answer in time")
        }
        return .failed(message.map { "\(what): \($0)" } ?? what)
    }

    static func isConnectionLost(_ rc: Int32) -> Bool {
        [LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV, LIBSSH2_ERROR_SOCKET_DISCONNECT,
         LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_CHANNEL_CLOSED,
         LIBSSH2_ERROR_CHANNEL_EOF_SENT, LIBSSH2_ERROR_KEX_FAILURE, LIBSSH2_ERROR_BAD_SOCKET].contains(rc)
    }

    static func isAuthRejection(_ rc: Int32) -> Bool {
        rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED || rc == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
            || rc == LIBSSH2_ERROR_METHOD_NOT_SUPPORTED || rc == LIBSSH2_ERROR_AGENT_PROTOCOL
    }

    // MARK: Helpers

    /// Host key algorithms for the known key types first, then the rest libssh2 offers.
    static func hostKeyMethods(knownTypes: [String], session: OpaquePointer) -> String {
        guard !knownTypes.isEmpty else { return "" }
        var list: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, LIBSSH2_METHOD_HOSTKEY, &list)
        guard count > 0, let list else { return "" }
        defer { libssh2_free(session, list) }
        let all = (0..<Int(count)).compactMap { list[$0].map { String(cString: $0) } }
        var first: [String] = []
        for type in knownTypes {
            let methods = type == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"] : [type]
            first += methods.filter { all.contains($0) && !first.contains($0) }
        }
        return (first + all.filter { !first.contains($0) }).joined(separator: ",")
    }

    /// A connected TCP socket (non-blocking connect with a timeout, then blocking).
    static func connectSocket(host: String, port: Int, timeout: Int32) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw VFSError.failed("Could not find \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(first) }
        var lastError: Int32 = ECONNREFUSED
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            node = info.pointee.ai_next
            let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { lastError = errno; continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if rc != 0, errno == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                rc = poll(&poller, 1, timeout)
                if rc == 1 {
                    var soError: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size)
                    rc = soError == 0 ? 0 : -1
                    if soError != 0 { errno = soError }
                } else {
                    if rc == 0 { errno = ETIMEDOUT }
                    rc = -1
                }
            }
            if rc == 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                return fd
            }
            lastError = errno
            Darwin.close(fd)
        }
        throw VFSError.failed("Could not connect to \(host) port \(port): \(String(cString: strerror(lastError)))")
    }
}

/// libssh2's keyboard-interactive callback: asks the connection's `keyboard` closure.
private let keyboardCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?, UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, count, prompts, responses, abstract in
    guard count > 0, let prompts, let responses, let pointer = abstract?.pointee else { return }
    let connection = Unmanaged<SSHConnection>.fromOpaque(pointer).takeUnretainedValue()
    let texts = (0..<Int(count)).map { i -> String in
        let prompt = prompts[i]
        guard let text = prompt.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(prompt.length)), as: UTF8.self)
    }
    guard let answers = connection.keyboard?(texts) else { return }
    for i in 0..<Int(count) {
        let answer = i < answers.count ? answers[i] : ""
        let bytes = Array(answer.utf8)
        let buffer = malloc(max(bytes.count, 1))!.assumingMemoryBound(to: CChar.self)
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(buffer, base, bytes.count) }
        }
        responses[i].text = buffer
        responses[i].length = UInt32(bytes.count)
    }
}

/// Private key files.
enum KeyFiles {
    /// The keys ssh tries when none is configured, in ssh's order.
    static func defaults(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["id_ed25519", "id_ecdsa", "id_rsa"].map { "\(home)/.ssh/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the key needs a passphrase: PEM "ENCRYPTED", or an OpenSSH key whose cipher is not "none".
    static func isEncrypted(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        if text.contains("ENCRYPTED") { return true }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { return false }
        let magic = Array("openssh-key-v1\0".utf8)
        let bytes = [UInt8](data)
        guard bytes.count > magic.count + 4, Array(bytes[0..<magic.count]) == magic else { return false }
        let start = magic.count
        let length = Int(bytes[start]) << 24 | Int(bytes[start + 1]) << 16 | Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
        guard start + 4 + length <= bytes.count else { return false }
        return String(decoding: bytes[(start + 4)..<(start + 4 + length)], as: UTF8.self) != "none"
    }
}
