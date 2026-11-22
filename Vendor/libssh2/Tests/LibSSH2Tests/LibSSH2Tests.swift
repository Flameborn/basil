import CLibSSH2
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
}
