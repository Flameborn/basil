import CBasilTLS
import CLibSSH2
import Darwin
import Testing

@Suite struct LibSSH2Tests {
    @Test func initialisesWithOpenSSL() throws {
        #expect(libssh2_init(0) == 0)
        defer { libssh2_exit() }
        let version = String(cString: try #require(libssh2_version(0)))
        #expect(version == "1.11.1")
        #expect(libssh2_crypto_engine() == libssh2_openssl)
    }

    @Test func makesASession() throws {
        #expect(libssh2_init(0) == 0)
        defer { libssh2_exit() }
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        defer { libssh2_session_free(session) }
        // Every algorithm Basil relies on is offered by this build.
        var list: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, LIBSSH2_METHOD_HOSTKEY, &list)
        #expect(count > 0)
        let methods = (0..<Int(max(count, 0))).compactMap { list?[$0].map { String(cString: $0) } }
        libssh2_free(session, list)
        #expect(methods.contains("ssh-ed25519"))
        #expect(methods.contains("ecdsa-sha2-nistp256"))
        #expect(methods.contains("rsa-sha2-512"))
    }

    /// libssl is linked and fails cleanly when the peer does not speak TLS (the FTP client's
    /// real handshakes are tested in BasilRemote against pure-ftpd).
    @Test func tlsHandshakeWithAPlainPeerFails() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let reply = "220 not TLS\r\n"
        _ = reply.withCString { write(fds[1], $0, strlen($0)) }
        shutdown(fds[1], SHUT_WR)
        var error = [CChar](repeating: 0, count: 256)
        let tls = basil_tls_connect(fds[0], "example.com", nil, &error, error.count)
        #expect(tls == nil)
        #expect(String(cString: error).hasPrefix("The TLS handshake failed"))
    }
}
