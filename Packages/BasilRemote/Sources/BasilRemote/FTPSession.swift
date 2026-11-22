import BasilCore
import BasilVFS
import Darwin
import Foundation

/// How a connection is protected.
enum FTPSecurity: Sendable, Hashable {
    /// Plain FTP: nothing is encrypted, and it never switches to TLS.
    case none
    /// FTPS explicit: AUTH TLS on the normal port; refuses to log in without TLS.
    case explicit
    /// FTPS implicit: TLS from the first byte (port 990).
    case implicit
}

/// How names are written on the wire.
enum FTPEncoding: String, Sendable, Hashable {
    case utf8 = "utf-8"
    case windows1252 = "windows-1252"

    func encode(_ text: String) -> Data? {
        switch self {
        case .utf8: Data(text.utf8)
        case .windows1252: text.data(using: .windowsCP1252)
        }
    }

    func decode(_ bytes: some Collection<UInt8>) -> String {
        switch self {
        case .utf8:
            // Servers that ignore OPTS UTF8 send other bytes; those names are read as Windows-1252.
            if let text = String(validating: Array(bytes), as: UTF8.self) { return text }
            return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        case .windows1252:
            return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Where a connection goes and how it behaves.
struct FTPEndpoint: Sendable, Hashable {
    var service: ProviderID
    var host: String
    var port: Int
    var defaultPort: Int
    /// "anonymous" for anonymous logins.
    var user: String
    var security: FTPSecurity
    var activeMode: Bool
    var encoding: FTPEncoding
    /// LIST -a on servers without MLSD.
    var listHidden: Bool
    /// Tests: act as if the server had no MLSD/MLST, MDTM, SIZE (the LIST path).
    var ignoreModernListing = false

    var anonymous: Bool { user.lowercased() == "anonymous" || user.lowercased() == "ftp" }
    /// "user@host" or "user@host:port".
    var account: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? "\(user)@\(name)" : "\(user)@\(name):\(port)"
    }
    /// "host" or "host:port", for certificate questions and the trust file.
    var hostAndPort: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? name : "\(name):\(port)"
    }
}

/// A server reply: the code and its text lines.
struct FTPReply: Sendable {
    var code: Int
    var lines: [String]

    var isPreliminary: Bool { (100..<200).contains(code) }
    var isPositive: Bool { (200..<300).contains(code) }
    var isIntermediate: Bool { (300..<400).contains(code) }

    /// The text without codes, lines joined.
    var text: String {
        lines.map { line in
            if line.count >= 4, line.prefix(3).allSatisfy(\.isNumber) { return String(line.dropFirst(4)) }
            return line.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

/// The server closed or broke the control connection: the session cannot be used again.
struct FTPConnectionLost: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// What the server said it supports (FEAT).
struct FTPFeatures: Sendable, Equatable {
    var mlsd = false
    var mlstFacts: Set<String> = []
    var utf8 = false
    var mfmt = false
    var mdtm = false
    var size = false
    var restStream = false
    var epsv = false
    var tls = false

    init() {}

    init(_ reply: FTPReply) {
        for raw in reply.lines.dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("MLST") {
                mlsd = true
                let facts = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                mlstFacts = Set(facts.split(separator: ";").map { $0.replacingOccurrences(of: "*", with: "").lowercased() })
            }
            if upper == "UTF8" { utf8 = true }
            if upper.hasPrefix("MFMT") { mfmt = true }
            if upper.hasPrefix("MDTM") { mdtm = true }
            if upper.hasPrefix("SIZE") { size = true }
            if upper.hasPrefix("REST STREAM") { restStream = true }
            if upper.hasPrefix("EPSV") { epsv = true }
            if upper.hasPrefix("AUTH") && upper.contains("TLS") { tls = true }
        }
    }
}

/// One FTP control connection. Every call runs on `queue` and blocks there (with timeouts),
/// never on the cooperative pool. A session serves one command or one transfer at a time; the
/// provider keeps several in a pool.
final class FTPSession: @unchecked Sendable {
    let endpoint: FTPEndpoint
    let queue: DispatchQueue

    static let connectTimeout: TimeInterval = 15
    static let ioTimeout: TimeInterval = 60

    // Only touched on `queue`.
    private var control: FTPSocket?
    private(set) var features = FTPFeatures()
    private(set) var greeting = ""
    /// EPSV failed once: PASV from then on.
    private var noEPSV = false
    /// Data connections are TLS (PROT P).
    private var protectData = false
    /// Set when the session must not be used again.
    var broken = false
    /// When the session last finished a command (for idle checks).
    var lastUsed = Date()
    /// The last refused rename step, for the error message.
    var lastRefusal: String?

    init(endpoint: FTPEndpoint) {
        self.endpoint = endpoint
        queue = DispatchQueue(label: "basil.ftp.\(endpoint.account)", qos: .userInitiated)
    }

    deinit { control?.close() }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    do { return try body() } catch let error as FTPConnectionLost {
                        self.broken = true
                        throw error
                    } catch is FTPTimeout {
                        self.broken = true
                        throw FTPConnectionLost(message: "\(self.endpoint.host) did not answer in time")
                    }
                })
            }
        }
    }

    // MARK: Connecting

    /// TCP connect, TLS for implicit FTPS, the greeting, and AUTH TLS for explicit FTPS.
    /// Returns the server's certificates (empty for plain FTP), to be checked before logging in.
    func open() throws -> [Data] {
        dispatchPrecondition(condition: .onQueue(queue))
        let socket = try FTPSocket.connect(host: endpoint.host, port: endpoint.port, timeout: Self.connectTimeout)
        control = socket
        if endpoint.security == .implicit {
            try socket.startTLS(serverName: endpoint.host, resume: nil)
        }
        socket.setTimeout(Self.ioTimeout)
        let hello = try readReply()
        guard hello.code == 220 else {
            if hello.code == 421 { throw VFSError.failed("\(endpoint.host) refused the connection: \(hello.text)") }
            throw VFSError.failed("\(endpoint.host) did not greet like an FTP server: \(hello.text)")
        }
        greeting = hello.text
        if endpoint.security == .explicit {
            let auth = try command("AUTH TLS")
            guard auth.code == 234 else {
                throw VFSError.failed("\(endpoint.host) does not offer TLS (AUTH TLS: \(auth.code) \(auth.text)). Use plain FTP only if you accept that the password is sent unencrypted.")
            }
            try socket.startTLS(serverName: endpoint.host, resume: nil)
        }
        return socket.certificates()
    }

    enum LoginResult: Equatable { case loggedIn, refused(String) }

    /// USER and PASS. `password` nil: the server must let the user in without one.
    func logIn(password: String?) throws -> LoginResult {
        let user = try command("USER " + endpoint.user)
        if user.code == 230 { return .loggedIn }
        if user.code == 530 { return .refused(user.text) }
        guard user.code == 331 || user.code == 332 else { throw failure(user, "Logging in") }
        guard let password else { return .refused("a password is needed") }
        let pass = try command("PASS " + password, secret: true)
        if pass.code == 230 || pass.code == 202 { return .loggedIn }
        if pass.code == 530 || pass.code == 430 { return .refused(pass.text) }
        if pass.code == 332 { throw VFSError.unsupported("FTP servers that ask for an account (ACCT)") }
        throw failure(pass, "Logging in")
    }

    /// After the login: features, UTF-8 names, protected data connections, binary transfers.
    func setUp() throws {
        let feat = try command("FEAT")
        features = feat.isPositive ? FTPFeatures(feat) : FTPFeatures()
        if endpoint.ignoreModernListing {
            features.mlsd = false
            features.mlstFacts = []
            features.mdtm = false
        }
        if endpoint.encoding == .utf8, features.utf8 {
            _ = try command("OPTS UTF8 ON")
        }
        if endpoint.security != .none {
            _ = try command("PBSZ 0")
            let prot = try command("PROT P")
            guard prot.isPositive else { throw VFSError.failed("\(endpoint.host) refused encrypted data connections (PROT P: \(prot.text))") }
            protectData = true
        }
        let type = try command("TYPE I")
        guard type.isPositive else { throw failure(type, "Switching to binary transfers") }
    }

    /// The login folder (PWD).
    func workingDirectory() throws -> String {
        let reply = try command("PWD")
        guard reply.code == 257, let line = reply.lines.first else { return "/" }
        // 257 "/home/a ""quoted"" name" is the current directory
        guard let open = line.firstIndex(of: "\"") else { return "/" }
        var result = ""
        var index = line.index(after: open)
        while index < line.endIndex {
            let c = line[index]
            if c == "\"" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "\"" {
                    result.append("\"")
                    index = line.index(after: next)
                    continue
                }
                break
            }
            result.append(c)
            index = line.index(after: index)
        }
        return result.hasPrefix("/") ? result : "/" + result
    }

    func close() {
        if control != nil, !broken {
            try? send("QUIT")
            _ = try? readReply()
        }
        control?.finish()
        control = nil
        broken = true
    }

    var tlsVersion: String? { control?.tlsVersion }

    // MARK: Commands

    /// Sends a command and reads its final reply (preliminary 1xx replies are skipped).
    @discardableResult
    func command(_ text: String, secret: Bool = false) throws -> FTPReply {
        try send(text)
        var reply = try readReply()
        while reply.isPreliminary { reply = try readReply() }
        lastUsed = Date()
        return reply
    }

    /// A command with a path argument. Paths with line breaks are refused: they would end the
    /// command early and start another.
    @discardableResult
    func command(_ verb: String, path: String) throws -> FTPReply {
        try command(verb + " " + Self.checked(path))
    }

    static func checked(_ path: String) throws -> String {
        if path.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw VFSError.failed("FTP cannot use names with line breaks")
        }
        return path
    }

    func send(_ text: String) throws {
        guard let control, !broken else { throw FTPConnectionLost(message: "The connection to \(endpoint.host) is closed") }
        guard var data = endpoint.encoding.encode(text) else {
            throw VFSError.failed("\(text.split(separator: " ").dropFirst().joined(separator: " ")) cannot be written in \(endpoint.encoding.rawValue)")
        }
        data.append(contentsOf: [0x0D, 0x0A])
        do { try control.write(data) } catch let error as FTPTimeout { throw error } catch {
            throw FTPConnectionLost(message: "The connection to \(endpoint.host) was lost (\(error.localizedDescription))")
        }
    }

    func readReply() throws -> FTPReply {
        guard let control else { throw FTPConnectionLost(message: "The connection to \(endpoint.host) is closed") }
        func line() throws -> String {
            let bytes: [UInt8]?
            do { bytes = try control.readLine() } catch let error as FTPTimeout { throw error } catch {
                throw FTPConnectionLost(message: "The connection to \(endpoint.host) was lost (\(error.localizedDescription))")
            }
            guard let bytes else { throw FTPConnectionLost(message: "\(endpoint.host) closed the connection") }
            return endpoint.encoding.decode(bytes)
        }
        let first = try line()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw FTPConnectionLost(message: "\(endpoint.host) sent something that is not an FTP reply")
        }
        var lines = [first]
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let end = String(first.prefix(3)) + " "
            while true {
                let next = try line()
                lines.append(next)
                if next.hasPrefix(end) || next == String(first.prefix(3)) { break }
            }
        }
        let reply = FTPReply(code: code, lines: lines)
        if code == 421 {
            broken = true
            throw FTPConnectionLost(message: "\(endpoint.host) closed the connection: \(reply.text)")
        }
        return reply
    }

    /// A refusal in words: "Deleting a.txt failed: 550 Permission denied".
    func failure(_ reply: FTPReply, _ action: String) -> VFSError {
        .failed("\(action) failed: \(reply.code) \(reply.text)")
    }

    // MARK: Data connections

    /// Opens a data connection and sends `command` over it ("RETR /a", "STOR /b", "MLSD /c").
    /// `restart` sends REST first. Returns once the server accepted the command (1xx).
    func openData(_ command: String, restart: Int64 = 0) throws -> FTPSocket {
        guard let control, !broken else { throw FTPConnectionLost(message: "The connection to \(endpoint.host) is closed") }
        if restart > 0 {
            let rest = try self.command("REST \(restart)")
            guard rest.code == 350 else { throw VFSError.unsupported("resuming a transfer in the middle (REST: \(rest.text))") }
        }
        var data: FTPSocket?
        var listener: FTPListener?
        if endpoint.activeMode {
            listener = try prepareActive(control)
        } else {
            data = try preparePassive(control)
        }
        do {
            try send(command)
            var accepted: FTPReply?
            /// Reads the reply to the transfer command; anything but 1xx ends the transfer.
            func readAcceptance() throws {
                let reply = try readReply()
                guard reply.isPreliminary else {
                    throw reply.code == 550 ? FTPRefusal(reply: reply) : failure(reply, Self.describe(command))
                }
                accepted = reply
            }
            if let listener {
                if let socket = try listener.accept(orReplyOn: control, timeout: Self.ioTimeout) {
                    data = socket
                } else {
                    try readAcceptance()
                    guard let socket = try listener.accept(orReplyOn: control, timeout: Self.ioTimeout) else {
                        let reply = try readReply()
                        throw failure(reply, Self.describe(command))
                    }
                    data = socket
                }
            }
            guard let socket = data else { throw VFSError.failed("No data connection") }
            socket.setTimeout(Self.ioTimeout)
            if protectData {
                try socket.startTLS(serverName: endpoint.host, resume: control, watching: control, timeout: Self.ioTimeout) {
                    try readAcceptance()
                }
            }
            if accepted == nil { try readAcceptance() }
            return socket
        } catch {
            data?.close()
            throw error
        }
    }

    /// "RETR /a/b" -> "Reading /a/b"
    static func describe(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1)
        let argument = parts.count > 1 ? " " + parts[1] : ""
        switch parts.first?.uppercased() {
        case "RETR": return "Reading" + argument
        case "STOR": return "Writing" + argument
        case "MLSD", "LIST", "NLST": return "Listing" + argument
        default: return command
        }
    }

    private func preparePassive(_ control: FTPSocket) throws -> FTPSocket {
        let peer = control.address(peer: true)
        if !noEPSV {
            let reply = try command("EPSV")
            if reply.code == 229, let port = Self.epsvPort(reply.text) {
                return try FTPSocket.connect(host: peer?.host ?? endpoint.host, port: port, timeout: Self.connectTimeout)
            }
            noEPSV = true
        }
        let reply = try command("PASV")
        guard reply.code == 227, let (address, port) = Self.pasvAddress(reply.text) else {
            throw failure(reply, "Opening a passive data connection")
        }
        let host = Self.passiveHost(reply: address, peer: peer?.host ?? endpoint.host)
        return try FTPSocket.connect(host: host, port: port, timeout: Self.connectTimeout)
    }

    private func prepareActive(_ control: FTPSocket) throws -> FTPListener {
        let listener = try FTPListener(like: control)
        let family = listener.address.family == AF_INET6 ? 2 : 1
        let eprt = try command("EPRT |\(family)|\(listener.address.host)|\(listener.port)|")
        if eprt.isPositive { return listener }
        guard family == 1 else { throw failure(eprt, "Opening an active data connection") }
        let octets = listener.address.host.split(separator: ".").joined(separator: ",")
        let port = try command("PORT \(octets),\(listener.port >> 8),\(listener.port & 0xFF)")
        guard port.isPositive else { throw failure(port, "Opening an active data connection") }
        return listener
    }

    /// "Entering Extended Passive Mode (|||6446|)"
    static func epsvPort(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let inner = text[text.index(after: open)..<close]
        guard let delimiter = inner.first else { return nil }
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count >= 4, let port = Int(fields[3]), (1...65535).contains(port) else { return nil }
        return port
    }

    /// "Entering Passive Mode (192,168,1,2,195,149)."
    static func pasvAddress(_ text: String) -> (String, Int)? {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 6 else { return nil }
        let six = Array(numbers.suffix(6))
        guard six.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return ("\(six[0]).\(six[1]).\(six[2]).\(six[3])", six[4] << 8 | six[5])
    }

    /// The PASV reply's address, unless a server behind NAT gave a private or empty one while
    /// the control connection goes elsewhere: then the control connection's address.
    static func passiveHost(reply address: String, peer: String) -> String {
        if address == peer { return address }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return peer }
        let isPrivate = octets[0] == 10 || octets[0] == 127 || octets[0] == 0
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
        let peerOctets = peer.split(separator: ".").compactMap { Int($0) }
        let peerIsPrivate = peerOctets.count == 4 && (peerOctets[0] == 10 || peerOctets[0] == 127
            || (peerOctets[0] == 172 && (16...31).contains(peerOctets[1])) || (peerOctets[0] == 192 && peerOctets[1] == 168))
        if isPrivate, !peerIsPrivate { return peer }
        if octets[0] == 0 { return peer }
        return address
    }

    /// Reads a whole listing and the reply after it.
    func listing(_ command: String) throws -> [UInt8] {
        let data = try openData(command)
        var bytes: [UInt8] = []
        while true {
            let piece: Data
            do { piece = try data.read(max: 64 * 1024) } catch {
                data.close()
                broken = true
                throw error
            }
            if piece.isEmpty { break }
            bytes.append(contentsOf: piece)
        }
        data.close()
        try finishTransfer(command)
        return bytes
    }

    /// The reply after a data connection was closed: 226 or 250 when the transfer was complete.
    func finishTransfer(_ command: String) throws {
        let reply = try readReply()
        lastUsed = Date()
        guard reply.isPositive else { throw failure(reply, Self.describe(command)) }
    }
}

/// A 550 reply to a transfer or listing: the item does not exist or cannot be used.
struct FTPRefusal: Error, LocalizedError {
    var reply: FTPReply
    var errorDescription: String? { "\(reply.code) \(reply.text)" }
}
