import BasilVFS
import CBasilTLS
import Darwin
import Foundation

/// One TCP connection of the FTP client, plain or TLS (libssl through CBasilTLS). Calls block
/// with the socket's timeouts and are made from one queue at a time (the owning session's).
final class FTPSocket: @unchecked Sendable {
    private(set) var fd: Int32
    private var tls: OpaquePointer?
    /// Bytes received but not yet handed out (control replies are read line by line).
    private var buffer: [UInt8] = []
    private var bufferStart = 0

    init(fd: Int32) {
        self.fd = fd
    }

    deinit { close() }

    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> FTPSocket {
        let fd = try SSHConnection.connectSocket(host: host, port: port, timeout: Int32(timeout * 1000))
        let socket = FTPSocket(fd: fd)
        socket.setTimeout(timeout)
        return socket
    }

    var isTLS: Bool { tls != nil }

    func setTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// TLS handshake on the open connection. `resume`: the control connection, whose TLS
    /// session a data connection resumes.
    func startTLS(serverName: String, resume: FTPSocket?) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let session = basil_tls_connect(fd, serverName, resume?.tls, &error, error.count) else {
            throw VFSError.failed(error.text)
        }
        tls = session
    }

    /// TLS handshake on a data connection while the control connection is watched: when a reply
    /// arrives there, `reply` reads it (and throws when the server refused the command, which
    /// ends the handshake). `reply` is called at most once.
    func startTLS(serverName: String, resume: FTPSocket, watching control: FTPSocket, timeout: TimeInterval,
                  reply: () throws -> Void) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let session = basil_tls_start(fd, serverName, resume.tls, &error, error.count) else {
            throw VFSError.failed(error.text)
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var watching = true
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let step = basil_tls_handshake(session, &error, error.count)
            if step == 1 { break }
            if step < 0 {
                basil_tls_free(session)
                throw VFSError.failed(error.text)
            }
            if watching, control.hasBufferedData {
                watching = false
                do { try reply() } catch { basil_tls_free(session); throw error }
                continue
            }
            var fds = [pollfd(fd: fd, events: Int16(step == 2 ? POLLOUT : POLLIN), revents: 0),
                       pollfd(fd: watching ? control.fd : -1, events: Int16(POLLIN), revents: 0)]
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                basil_tls_free(session)
                throw VFSError.failed("The TLS handshake on the data connection timed out")
            }
            let rc = poll(&fds, 2, Int32(left * 1000))
            if rc < 0, errno != EINTR {
                basil_tls_free(session)
                throw VFSError.failed("The TLS handshake on the data connection failed: \(String(cString: strerror(errno)))")
            }
            if watching, fds[1].revents != 0 {
                watching = false
                do { try reply() } catch { basil_tls_free(session); throw error }
            }
        }
        tls = session
    }

    var hasBufferedData: Bool { bufferStart < buffer.count }

    /// The certificates the server sent, leaf first, as DER.
    func certificates() -> [Data] {
        guard let tls else { return [] }
        return (0..<basil_tls_certificate_count(tls)).compactMap { index in
            var der: UnsafeMutablePointer<UInt8>?
            let length = basil_tls_certificate(tls, index, &der)
            guard length > 0, let der else { return nil }
            defer { basil_tls_free_buffer(der) }
            return Data(bytes: der, count: Int(length))
        }
    }

    var tlsVersion: String? { tls.map { String(cString: basil_tls_version($0)) } }
    var resumedSession: Bool { tls.map { basil_tls_resumed($0) == 1 } ?? false }

    // MARK: Reading and writing

    /// Up to `count` bytes; empty at the end of the stream.
    func read(max count: Int) throws -> Data {
        if bufferStart < buffer.count {
            let end = min(buffer.count, bufferStart + count)
            let data = Data(buffer[bufferStart..<end])
            bufferStart = end
            if bufferStart == buffer.count { buffer = []; bufferStart = 0 }
            return data
        }
        var data = Data(count: count)
        let got = try data.withUnsafeMutableBytes { try receive($0.baseAddress!, count) }
        data.count = got
        return data
    }

    /// Fills exactly `count` bytes unless the stream ends first.
    func read(exactly count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let piece = try read(max: count - data.count)
            if piece.isEmpty { break }
            data.append(piece)
        }
        return data
    }

    /// One line without its CR LF (a lone LF also ends it). nil at the end of the stream.
    func readLine(limit: Int = 64 * 1024) throws -> [UInt8]? {
        while true {
            if let newline = buffer[bufferStart...].firstIndex(of: 0x0A) {
                var line = Array(buffer[bufferStart..<newline])
                if line.last == 0x0D { line.removeLast() }
                bufferStart = newline + 1
                if bufferStart == buffer.count { buffer = []; bufferStart = 0 }
                return line
            }
            if buffer.count - bufferStart > limit { throw VFSError.failed("The server sent a line that is too long") }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let got = try chunk.withUnsafeMutableBytes { try receive($0.baseAddress!, 4096) }
            if got == 0 {
                guard bufferStart < buffer.count else { return nil }
                let line = Array(buffer[bufferStart...])
                buffer = []
                bufferStart = 0
                return line
            }
            if bufferStart > 0 {
                buffer.removeFirst(bufferStart)
                bufferStart = 0
            }
            buffer.append(contentsOf: chunk.prefix(got))
        }
    }

    private func receive(_ pointer: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        guard fd >= 0 else { throw VFSError.failed("The connection is closed") }
        if let tls {
            var timedOut: Int32 = 0
            var error = [CChar](repeating: 0, count: 512)
            let got = basil_tls_read(tls, pointer, count, &timedOut, &error, error.count)
            if got >= 0 { return got }
            if timedOut != 0 { throw FTPTimeout() }
            throw VFSError.failed(error.text)
        }
        while true {
            let got = Darwin.recv(fd, pointer, count, 0)
            if got >= 0 { return got }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw FTPTimeout() }
            throw VFSError.failed("Reading from the server failed: \(String(cString: strerror(errno)))")
        }
    }

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw VFSError.failed("The connection is closed") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let tls {
                var error = [CChar](repeating: 0, count: 512)
                guard basil_tls_write(tls, base, data.count, &error, error.count) == 0 else {
                    throw VFSError.failed(error.text)
                }
                return
            }
            var sent = 0
            while sent < data.count {
                let rc = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if rc < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw FTPTimeout() }
                    throw VFSError.failed("Sending to the server failed: \(String(cString: strerror(errno)))")
                }
                sent += rc
            }
        }
    }

    /// Ends an upload cleanly: close_notify over TLS, our side shut, then whatever the server
    /// still sends (TLS 1.3 session tickets nobody read) is drained until it closes. Closing a
    /// socket with unread bytes sends a reset, and the server would report the upload as broken.
    func finish() {
        if let tls { basil_tls_shutdown(tls) }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_WR)
            setTimeout(5)
            var scratch = [UInt8](repeating: 0, count: 16 * 1024)
            while Darwin.recv(fd, &scratch, scratch.count, 0) > 0 {}
        }
        close()
    }

    func close() {
        if let tls {
            basil_tls_free(tls)
            self.tls = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: Addresses

    /// The numeric address and port of either end.
    func address(peer: Bool) -> (host: String, port: Int, family: Int32)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length)
            }
        }
        guard rc == 0 else { return nil }
        return Self.describe(storage, length)
    }

    static func describe(_ storage: sockaddr_storage, _ length: socklen_t) -> (host: String, port: Int, family: Int32)? {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard rc == 0 else { return nil }
        var name = host.text
        // A zone index ("fe80::1%en0") is not part of what the server needs.
        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
        return (name, Int(service.text) ?? 0, Int32(storage.ss_family))
    }
}

/// A socket read or write ran out of time.
struct FTPTimeout: Error, LocalizedError {
    var errorDescription: String? { "The server did not answer in time" }
}

/// A listening socket for active mode (the server connects to it).
final class FTPListener: @unchecked Sendable {
    let fd: Int32
    let port: Int

    /// Listens on the address the control connection uses locally (any port).
    init(like control: FTPSocket) throws {
        guard let local = control.address(peer: false) else { throw VFSError.failed("Could not find this Mac's address for active mode") }
        var hints = addrinfo()
        hints.ai_family = local.family
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST | AI_PASSIVE
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(local.host, "0", &hints, &result) == 0, let info = result else {
            throw VFSError.failed("Could not listen for the server's data connection")
        }
        defer { freeaddrinfo(info) }
        let fd = socket(info.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw VFSError.failed("Could not listen for the server's data connection") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw VFSError.failed("Could not listen for the server's data connection: \(String(cString: strerror(errno)))")
        }
        self.fd = fd
        let probe = FTPSocket(fd: fd)
        port = probe.address(peer: false)?.port ?? 0
        // `probe` must not close the listener.
        probe.detach()
        address = (local.host, local.family)
    }

    let address: (host: String, family: Int32)

    deinit { Darwin.close(fd) }

    /// Waits for the server to connect, or for the control connection to have a reply (a
    /// refusal). Returns nil when the control connection spoke first.
    func accept(orReplyOn control: FTPSocket, timeout: TimeInterval) throws -> FTPSocket? {
        if control.hasBufferedData { return nil }
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: control.fd, events: Int16(POLLIN), revents: 0)]
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            let rc = poll(&fds, 2, left)
            if rc < 0, errno == EINTR { continue }
            if rc == 0 { throw VFSError.failed("The server did not open the data connection (active mode)") }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { throw VFSError.failed("Accepting the data connection failed: \(String(cString: strerror(errno)))") }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                return FTPSocket(fd: client)
            }
            if fds[1].revents != 0 { return nil }
        }
    }
}

extension FTPSocket {
    /// Forgets the descriptor without closing it.
    fileprivate func detach() { fd = -1 }
}

extension Array where Element == CChar {
    /// The NUL-terminated text in a C buffer.
    var text: String {
        let bytes = prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
