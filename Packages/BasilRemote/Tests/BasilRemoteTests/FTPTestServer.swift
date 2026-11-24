import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilRemote

/// pure-ftpd built by scripts/build-test-ftpd.sh (run here when missing), started as the test
/// user on free ports of 127.0.0.1: one server for plain FTP and explicit TLS, one built for
/// implicit TLS. Both use a self-signed certificate for "localhost" and one virtual account
/// without a chroot, so server paths are this Mac's paths and tests check
/// results with FileManager. Started once and stopped when the test process exits.
final class FTPTestServer: Sendable {
    static let shared: FTPTestServer? = {
        do { return try FTPTestServer() } catch {
            print("FTP test server: \(error)")
            return nil
        }
    }()

    let folder: URL
    let port: Int
    let implicitPort: Int
    let user = "basil"
    let password = "ftp secret"
    let certificate: URL

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    init() throws {
        let tools = Self.repository.appendingPathComponent("build/test-ftpd")
        if !FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("pure-ftpd-implicit").path) {
            try TestServer.run("/bin/sh", [Self.repository.appendingPathComponent("scripts/build-test-ftpd.sh").path])
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-ftpd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.path
        TestServer.folders.withLock { $0.append(path) }
        // The key and certificate in one file, as pure-ftpd wants them.
        certificate = folder.appendingPathComponent("cert.pem")
        let key = folder.appendingPathComponent("key.pem")
        let crt = folder.appendingPathComponent("crt.pem")
        try TestServer.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                                                "-subj", "/CN=localhost", "-keyout", key.path, "-out", crt.path])
        let pem = try String(contentsOf: key, encoding: .utf8) + String(contentsOf: crt, encoding: .utf8)
        try pem.write(to: certificate, atomically: true, encoding: .utf8)

        let passwd = folder.appendingPathComponent("passwd").path
        let pdb = folder.appendingPathComponent("pureftpd.pdb").path
        let pw = Process()
        pw.executableURL = tools.appendingPathComponent("pure-pw")
        pw.arguments = ["useradd", user, "-u", "\(getuid())", "-g", "\(getgid())", "-D", folder.path, "-f", passwd, "-F", pdb, "-m"]
        let input = Pipe()
        pw.standardInput = input
        pw.standardOutput = FileHandle.nullDevice
        try pw.run()
        input.fileHandleForWriting.write(Data("\(password)\n\(password)\n".utf8))
        try input.fileHandleForWriting.close()
        pw.waitUntilExit()
        guard pw.terminationStatus == 0 else { throw VFSError.failed("pure-pw failed") }

        port = TestServer.freePort()
        implicitPort = TestServer.freePort()
        let common = ["-l", "puredb:\(pdb)", "-E", "-z", "-H", "-Y", "1", "-2", certificate.path, "-I", "300"]
        try TestServer.start(tools.appendingPathComponent("pure-ftpd").path,
                             ["-S", "127.0.0.1,\(port)", "-p", "40000:40999"] + common,
                             log: folder.appendingPathComponent("ftpd.log"))
        try TestServer.start(tools.appendingPathComponent("pure-ftpd-implicit").path,
                             ["-S", "127.0.0.1,\(implicitPort)", "-p", "41000:41999"] + common,
                             log: folder.appendingPathComponent("ftpd-implicit.log"))
        for p in [port, implicitPort] {
            try TestServer.waitFor { (try? SSHConnection.connectSocket(host: "127.0.0.1", port: p, timeout: 200)).map { close($0); return true } ?? false }
        }
    }

    func connector(_ kind: FTPConnector.Kind, trustFile: URL, ignoreModernListing: Bool = false) -> FTPConnector {
        var connector = FTPConnector(kind, trustFile: trustFile)
        connector.ignoreModernListing = ignoreModernListing
        return connector
    }

    func target(_ kind: FTPConnector.Kind, path: String?, options: [String: String]? = nil) -> RemoteTarget {
        let service: ProviderID = switch kind {
        case .plain: .ftp
        case .explicitTLS: .ftpes
        case .implicitTLS: .ftps
        }
        return RemoteTarget(service: service, host: "127.0.0.1", port: kind == .implicitTLS ? implicitPort : port,
                            user: user, path: path, authentication: .password, options: options)
    }
}

/// Scripted answers for FTP connections (certificates and passwords).
final class FTPPrompts: RemotePrompts {
    struct State {
        var certificateAnswer: HostKeyAnswer = .trustOnce
        var certificateQuestions: [CertificateQuestion] = []
        var secrets: [String?] = []
        var secretRequests: [SecretRequest] = []
        var worked = 0
        /// Answers ask to remember the secret.
        var remember = false
    }

    let state: Mutex<State>

    init(certificate: HostKeyAnswer = .trustOnce, secrets: [String?]) {
        state = Mutex(State(certificateAnswer: certificate, secrets: secrets))
    }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer { .cancel }

    func certificate(_ question: CertificateQuestion) async -> HostKeyAnswer {
        state.withLock { $0.certificateQuestions.append(question); return $0.certificateAnswer }
    }

    func secret(_ request: SecretRequest) async -> SecretAnswer? {
        state.withLock { s in
            s.secretRequests.append(request)
            guard !s.secrets.isEmpty, let next = s.secrets.removeFirst() else { return nil }
            return SecretAnswer(secret: next, remember: s.remember)
        }
    }

    func secretWorked(_ request: SecretRequest, _ answer: SecretAnswer) async {
        state.withLock { $0.worked += 1 }
    }
}


