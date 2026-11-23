import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// How a new session of an open connection logs in again without asking: the password that
/// worked and the certificate the user accepted (or the system trusted).
struct FTPLogin: Sendable {
    var password: String?
    /// SHA-256 of the accepted leaf certificate; nil when the system's trust is enough.
    var acceptedCertificate: Data?
}

/// The control connections of one FTP connection. A control connection does one thing at a
/// time (a listing, a command, one transfer), so a copy that reads and writes on the same server,
/// or a pane listing during a transfer, needs more than one. Sessions are opened as needed, up
/// to `limit`; when the server refuses more ("too many connections"), the limit drops to what is
/// open and callers wait for a free one.
final class FTPPool: Sendable {
    let endpoint: FTPEndpoint
    let login: FTPLogin
    let trust: CertificateTrust

    private struct State {
        var idle: [FTPSession] = []
        var open = 0
        var limit = 4
        var waiting: [CheckedContinuation<FTPSession?, Never>] = []
        var closed = false
    }

    private let state: Mutex<State>

    /// Idle sessions older than this get a NOOP before use (servers drop idle connections).
    static let idleCheck: TimeInterval = 30

    init(endpoint: FTPEndpoint, login: FTPLogin, trust: CertificateTrust, first: FTPSession) {
        self.endpoint = endpoint
        self.login = login
        self.trust = trust
        state = Mutex(State(idle: [first], open: 1))
    }

    var features: FTPFeatures { state.withLock { $0.idle.first?.features } ?? FTPFeatures() }

    /// A session for the caller alone, until `release`.
    func acquire() async throws -> FTPSession {
        while true {
            enum Next { case session(FTPSession), open, wait }
            let next: Next = try state.withLock { s in
                if s.closed { throw VFSError.failed("The connection to \(endpoint.host) was closed") }
                if let session = s.idle.popLast() { return .session(session) }
                if s.open < s.limit {
                    s.open += 1
                    return .open
                }
                return .wait
            }
            switch next {
            case .session(let session):
                if Date().timeIntervalSince(session.lastUsed) > Self.idleCheck {
                    let alive = (try? await session.run { try session.command("NOOP").isPositive }) ?? false
                    if !alive {
                        discard(session)
                        continue
                    }
                }
                return session
            case .open:
                do {
                    return try await openSession()
                } catch let error as FTPConnectionLost {
                    // Refused (421): no more connections allowed. Wait for one in use, if any.
                    let canWait = state.withLock { s in
                        s.open -= 1
                        if s.open > 0 { s.limit = s.open }
                        return s.open > 0
                    }
                    if !canWait { throw VFSError.failed(error.message) }
                } catch {
                    state.withLock { $0.open -= 1 }
                    throw error
                }
            case .wait:
                if let session = await withCheckedContinuation({ continuation in
                    state.withLock { $0.waiting.append(continuation) }
                }) {
                    return session
                }
            }
        }
    }

    /// Gives a session back. A broken one is closed and its place freed.
    func release(_ session: FTPSession) {
        if session.broken {
            discard(session)
            return
        }
        let waiter: CheckedContinuation<FTPSession?, Never>? = state.withLock { s in
            if s.closed { return nil }
            if !s.waiting.isEmpty { return s.waiting.removeFirst() }
            s.idle.append(session)
            return nil
        }
        if let waiter {
            waiter.resume(returning: session)
        } else if state.withLock({ $0.closed }) {
            session.queue.async { session.close() }
        }
    }

    private func discard(_ session: FTPSession) {
        let waiter: CheckedContinuation<FTPSession?, Never>? = state.withLock { s in
            s.open -= 1
            // Someone waiting may open a new session now.
            return s.waiting.isEmpty ? nil : s.waiting.removeFirst()
        }
        session.queue.async { session.close() }
        waiter?.resume(returning: nil)
    }

    /// Runs a command on a free session. A session that turns out to be dead (the server dropped
    /// it) is replaced once.
    func run<T: Sendable>(_ body: @escaping @Sendable (FTPSession) throws -> T) async throws -> T {
        var tries = 0
        while true {
            let session = try await acquire()
            do {
                let value = try await session.run { try body(session) }
                release(session)
                return value
            } catch let error as FTPConnectionLost {
                release(session)
                tries += 1
                if tries > 1 { throw VFSError.failed(error.message) }
            } catch {
                release(session)
                throw error
            }
        }
    }

    /// A new session logged in like the first one, without questions.
    private func openSession() async throws -> FTPSession {
        let session = FTPSession(endpoint: endpoint)
        let endpoint = endpoint
        let login = login
        let trust = trust
        do {
            try await session.run {
                let certificates = try session.open()
                if endpoint.security != .none {
                    try trust.verifySilently(certificates, endpoint: endpoint, accepted: login.acceptedCertificate)
                }
                switch try session.logIn(password: login.password) {
                case .loggedIn: break
                case .refused(let text): throw VFSError.failed("\(endpoint.host) refused the login again: \(text)")
                }
                try session.setUp()
            }
            return session
        } catch {
            session.queue.async { session.close() }
            throw error
        }
    }

    func closeAll() async {
        let (sessions, waiters) = state.withLock { s in
            s.closed = true
            let result = (s.idle, s.waiting)
            s.idle = []
            s.waiting = []
            return result
        }
        for waiter in waiters { waiter.resume(returning: nil) }
        for session in sessions {
            _ = try? await session.run { session.close() }
        }
    }
}
