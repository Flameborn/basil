import BasilVFS
import Darwin
import Foundation
import Synchronization

/// The page a browser sign-in comes back to: a tiny HTTP server on this Mac only (127.0.0.1 and
/// ::1), listening only while a sign-in waits. Dropbox sends the browser to
/// "http://localhost:21745/dropbox?code=...&state=..."; the server hands the address to the
/// sign-in waiting for that state and shows a page that says the tab can be closed.
final class SignInReturnServer: @unchecked Sendable {
    /// Basil's port (unlikely to be taken; DropboxConnector's default too). Registered as a redirect address in the
    /// Dropbox App Console, so it cannot change per sign-in.
    static let basilPort: UInt16 = 21745

    let port: UInt16
    private let listeners: [Int32]
    private let handler: @Sendable (URL) -> Page
    private let stopped = Atomic<Bool>(false)

    /// What the browser shows.
    struct Page: Sendable {
        var status = 200
        var title: String
        var message: String
    }

    /// Starts listening on `port` (0 picks a free one, for tests). Throws `SignInReturnError`
    /// when the port is taken, naming the app that has it when macOS says.
    init(port: UInt16 = SignInReturnServer.basilPort, service: String,
         handler: @escaping @Sendable (URL) -> Page) throws {
        self.handler = handler
        var fds: [Int32] = []
        var chosen = port
        // IPv4 first: its failure is the one that matters ("localhost" works over either).
        let v4 = try Self.listen(ipv6: false, port: chosen, service: service)
        fds.append(v4.fd)
        chosen = v4.port
        if let v6 = try? Self.listen(ipv6: true, port: chosen, service: service) { fds.append(v6.fd) }
        listeners = fds
        self.port = chosen
        for fd in fds {
            let thread = Thread { [self] in acceptLoop(fd) }
            thread.name = "Basil sign-in return"
            thread.start()
        }
    }

    deinit { stop() }

    func stop() {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        for fd in listeners {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    // MARK: Socket

    private static func listen(ipv6: Bool, port: UInt16, service: String) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SignInReturnError.failed(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let bound: Int32
        if ipv6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            address.sin6_port = port.bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                throw SignInReturnError.portInUse(port: port, app: owner(of: port), service: service)
            }
            throw SignInReturnError.failed(String(cString: strerror(code)))
        }
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let actual = withUnsafePointer(to: &address) { pointer -> UInt16 in
            if ipv6 {
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        return (fd, actual)
    }

    /// The name of the app listening on `port`, from lsof (nil when it does not say).
    static func owner(of port: UInt16) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read to the end (lsof has exited then); no waitUntilExit, which has hung in Basil before.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // -Fc prints "p<pid>" and "c<command>" lines.
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }

    private func acceptLoop(_ fd: Int32) {
        while !stopped.load(ordering: .relaxed) {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(connection)
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16384, request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(connection, &buffer, buffer.count, 0)
            if n <= 0 { break }
            request.append(contentsOf: buffer[0..<n])
        }
        let line = String(decoding: request.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
        let parts = line.split(separator: " ")
        let page: Page
        if parts.count >= 2, parts[0] == "GET", let url = URL(string: "http://localhost:\(port)" + parts[1]),
           url.path != "/favicon.ico" {
            page = handler(url)
        } else {
            page = Page(status: 404, title: "Not found", message: "There is nothing here.")
        }
        let body = Data(Self.html(page).utf8)
        let reason = page.status == 200 ? "OK" : "Not Found"
        let head = "HTTP/1.1 \(page.status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + body
        _ = response.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
    }

    // MARK: Page

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ page: Page) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Basil: \(escape(page.title))</title>
        <style>
        body { font: 17px -apple-system, system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid;
               place-items: center; background: #F4F8EF; color: #1B2A1C; }
        main { max-width: 32rem; padding: 2rem; text-align: center; }
        h1 { font-size: 1.6rem; color: #2E6B33; margin: 0 0 0.75rem; }
        p { line-height: 1.5; margin: 0.5rem 0; }
        @media (prefers-color-scheme: dark) {
          body { background: #172018; color: #E8F0E4; }
          h1 { color: #9BD68F; }
        }
        </style>
        </head>
        <body>
        <main>
        <h1>\(escape(page.title))</h1>
        <p>\(escape(page.message))</p>
        </main>
        </body>
        </html>
        """
    }
}

enum SignInReturnError: Error, LocalizedError, Equatable {
    case portInUse(port: UInt16, app: String?, service: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .portInUse(let port, let app, let service):
            let who = app.map { "\($0) is using it" } ?? "another app is using it"
            return "Basil signs in to \(service) through port \(port) on this Mac, but \(who). Quit \(app ?? "that app") and connect again."
        case .failed(let text):
            return "Basil could not wait for the sign-in: \(text)"
        }
    }
}
