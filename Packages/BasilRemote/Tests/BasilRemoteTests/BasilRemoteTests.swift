import BasilCore
import BasilVFS
import CryptoKit
import Foundation
import Testing
@testable import BasilRemote

@Suite struct RemoteTargetTests {
    @Test func parsesAddresses() {
        let full = RemoteTarget.parse("sftp://erion@example.com:2222/srv/www", defaultService: .sftp)
        #expect(full == RemoteTarget(service: .sftp, host: "example.com", port: 2222, user: "erion", path: "/srv/www"))
        #expect(RemoteTarget.parse("example.com", defaultService: .sftp)
            == RemoteTarget(service: .sftp, host: "example.com"))
        #expect(RemoteTarget.parse(" me@box ", defaultService: .sftp)?.user == "me")
        let v6 = RemoteTarget.parse("[::1]:2200", defaultService: .sftp)
        #expect(v6?.host == "::1" && v6?.port == 2200)
        #expect(RemoteTarget.parse("fe80::1", defaultService: .sftp)?.host == "fe80::1")
        #expect(RemoteTarget.parse("a%40b@host", defaultService: .sftp)?.user == "a@b")
        #expect(RemoteTarget.parse("user@", defaultService: .sftp) == nil)
        #expect(RemoteTarget.parse("ftp://host", defaultService: .sftp)?.service == ProviderID("ftp"))
    }
}

@Suite struct SSHConfigTests {
    let text = """
    # comment
    Host web prod-*  !prod-db
        HostName %h.example.com
        User deploy
        Port 2200
        IdentityFile ~/.ssh/deploy_%r
        ProxyJump bastion

    Host web
        User ignored
        IdentityFile /keys/second

    Match host other
        User matched

    Host *
        User everyone
        IdentitiesOnly=yes
        Port = 22
    """

    @Test func firstValueWinsAndIdentitiesCollect() {
        let config = SSHConfig(text: text).resolve("web", localUser: "me", home: "/Users/me")
        #expect(config.hostName == "web.example.com")
        #expect(config.user == "deploy")
        #expect(config.port == 2200)
        #expect(config.identitiesOnly == true)
        #expect(config.identityFiles == ["/Users/me/.ssh/deploy_deploy", "/keys/second"])
        #expect(config.unsupported.contains("ProxyJump bastion"))
        #expect(config.unsupported.contains("Match"))
    }

    @Test func wildcardsAndNegation() {
        let config = SSHConfig(text: text)
        #expect(config.resolve("prod-app").user == "deploy")
        #expect(config.resolve("prod-db").user == "everyone")
        #expect(config.resolve("PROD-APP").user == "deploy")
        #expect(config.resolve("other").hostName == nil)
        #expect(config.aliases == ["web"])
    }

    @Test func followsIncludes() throws {
        let folder = TestScratch.url.appendingPathComponent("basil-sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Host box\n  HostName 10.0.0.5\n".write(to: folder.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
        let config = SSHConfig(text: "Include conf.d/*.conf\nHost *\n  User x\n", includeBase: folder)
        #expect(config.resolve("box").hostName == "10.0.0.5")
        #expect(config.resolve("box").user == "x")
    }
}

@Suite struct KnownHostsTests {
    func blob(_ type: String, _ body: [UInt8]) -> Data {
        var data = Data([0, 0, 0, UInt8(type.utf8.count)])
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: [0, 0, 0, UInt8(body.count)] + body)
        return data
    }

    func file(_ text: String) throws -> URL {
        let url = TestScratch.url.appendingPathComponent("basil-kh-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func hashed(_ host: String, salt: Data) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(host.utf8), using: SymmetricKey(data: salt))
        return "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
    }

    @Test func checksPlainHashedAndPorts() throws {
        let ed = blob("ssh-ed25519", [1, 2, 3])
        let other = blob("ssh-ed25519", [9, 9, 9])
        let rsa = blob("ssh-rsa", [4, 5])
        let salt = Data((0..<20).map { UInt8($0) })
        let url = try file("""
        # mine
        example.com,10.0.0.1 ssh-ed25519 \(ed.base64EncodedString()) comment here
        \(hashed("[secret.org]:2222", salt: salt)) ssh-rsa \(rsa.base64EncodedString())
        @cert-authority *.corp ssh-ed25519 \(other.base64EncodedString())
        @revoked bad.example ssh-ed25519 \(other.base64EncodedString())
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let known = KnownHosts(file: url)
        #expect(known.check(host: "example.com", key: ed) == .known)
        #expect(known.check(host: "10.0.0.1", key: ed) == .known)
        #expect(known.check(host: "example.com", key: other) == .changed)
        #expect(known.check(host: "example.com", key: rsa) == .unknown)
        #expect(known.check(host: "[secret.org]:2222", key: rsa) == .known)
        #expect(known.check(host: "secret.org", key: rsa) == .unknown)
        #expect(known.check(host: "a.corp", key: other) == .unknown)
        #expect(known.check(host: "bad.example", key: other) == .revoked)
        #expect(known.keyTypes(for: "example.com") == ["ssh-ed25519"])
        #expect(KnownHosts.hostName("h", port: 22) == "h" && KnownHosts.hostName("h", port: 2) == "[h]:2")
    }

    @Test func rememberAppendsOrReplacesOneLine() throws {
        let old = blob("ssh-ed25519", [1])
        let new = blob("ssh-ed25519", [2])
        let url = try file("# keep me\nhost.one ssh-ed25519 \(old.base64EncodedString())\nshared,host.two ssh-ed25519 \(old.base64EncodedString())\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var known = KnownHosts(file: url)
        try known.remember(host: "host.one", key: new)
        try known.remember(host: "[added]:2200", key: new)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == """
        # keep me
        host.one ssh-ed25519 \(new.base64EncodedString())
        shared,host.two ssh-ed25519 \(old.base64EncodedString())
        [added]:2200 ssh-ed25519 \(new.base64EncodedString())

        """)
        #expect(KnownHosts(file: url).check(host: "host.one", key: new) == .known)
    }

    @Test func fingerprintsLikeSSH() {
        let key = blob("ssh-ed25519", Array(repeating: 7, count: 32))
        let expected = "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(KnownHosts.fingerprint(of: key) == expected)
        #expect(KnownHosts.displayType(of: key) == "ED25519")
    }
}
