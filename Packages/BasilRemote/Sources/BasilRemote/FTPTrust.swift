import BasilVFS
import CBasilTLS
import CryptoKit
import Foundation
import Security

/// Checks FTPS certificates: first against the system's trust (as Safari would, including the
/// host name), then against certificates the user chose to trust for that server. Those are kept
/// in a text file, one "host:port sha256-hex" line per server.
struct FTPTrust: Sendable {
    let file: URL

    /// What the system says about a chain.
    struct Evaluation: Sendable {
        var trusted: Bool
        /// Why not, in words.
        var reason: String
    }

    static func evaluate(_ chain: [Data], host: String) -> Evaluation {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return Evaluation(trusted: false, reason: "The server sent no certificate") }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return Evaluation(trusted: false, reason: "The certificate could not be checked")
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return Evaluation(trusted: true, reason: "") }
        let text = (error.map { CFErrorCopyDescription($0) as String }) ?? "The certificate is not trusted"
        return Evaluation(trusted: false, reason: text)
    }

    static func fingerprint(_ der: Data) -> Data { Data(SHA256.hash(data: der)) }

    /// "SHA256:AB:CD:..."
    static func displayFingerprint(_ digest: Data) -> String {
        "SHA256:" + digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Remembered certificates

    func remembered(for host: String) -> Data? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == host { return Data(hex: String(parts[1])) }
        }
        return nil
    }

    func remember(_ digest: Data, for host: String) throws {
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(host + " ") }
        lines.append(host + " " + digest.map { String(format: "%02x", $0) }.joined())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Checking

    /// The first connection: asks the user when the system does not trust the certificate and
    /// it is not the one remembered. Returns the accepted leaf's fingerprint (nil when the system
    /// trusts the chain).
    func verify(_ chain: [Data], endpoint: FTPEndpoint, prompts: any RemotePrompts) async throws -> Data? {
        guard let leaf = chain.first else { throw VFSError.failed("\(endpoint.host) sent no TLS certificate") }
        let evaluation = Self.evaluate(chain, host: endpoint.host)
        if evaluation.trusted { return nil }
        let digest = Self.fingerprint(leaf)
        let saved = remembered(for: endpoint.hostAndPort)
        if saved == digest { return digest }
        let info = Self.describe(leaf)
        let question = CertificateQuestion(
            reason: saved == nil ? .untrusted(evaluation.reason) : .changed(evaluation.reason),
            host: endpoint.hostAndPort, subject: info.subject, issuer: info.issuer, validity: info.validity,
            fingerprint: Self.displayFingerprint(digest), trustFile: file.path)
        switch await prompts.certificate(question) {
        case .cancel: throw RemoteCancelled()
        case .trustOnce: return digest
        case .trustAndRemember:
            do { try remember(digest, for: endpoint.hostAndPort) } catch {
                await prompts.note("Could not save the certificate in \(file.path): \(error.localizedDescription)")
            }
            return digest
        }
    }

    /// Later sessions of a connection: the chain must be trusted by the system or be the one
    /// accepted for the first session.
    func verifySilently(_ chain: [Data], endpoint: FTPEndpoint, accepted: Data?) throws {
        guard let leaf = chain.first else { throw VFSError.failed("\(endpoint.host) sent no TLS certificate") }
        if Self.evaluate(chain, host: endpoint.host).trusted { return }
        if let accepted, Self.fingerprint(leaf) == accepted { return }
        throw VFSError.failed("The TLS certificate of \(endpoint.host) changed while connected. Connect again to check it.")
    }

    /// The certificate's subject, issuer and expiry in words.
    static func describe(_ der: Data) -> (subject: String, issuer: String, validity: String) {
        var subject = [CChar](repeating: 0, count: 512)
        var issuer = [CChar](repeating: 0, count: 512)
        var notAfter: Int64 = 0
        let rc = der.withUnsafeBytes { raw in
            basil_tls_describe_certificate(raw.bindMemory(to: UInt8.self).baseAddress, Int32(der.count),
                                           &subject, subject.count, &issuer, issuer.count, &notAfter)
        }
        guard rc == 0 else { return ("unknown", "unknown", "") }
        var validity = ""
        if notAfter != 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(notAfter))
            let formatted = date.formatted(date: .long, time: .omitted)
            validity = date < Date() ? "expired on \(formatted)" : "valid until \(formatted)"
        }
        return (subject.text, issuer.text, validity)
    }
}

extension Data {
    /// Reads lower- or upper-case hex; nil for anything else.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
