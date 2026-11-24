import BasilCore
import BasilVFS
import CryptoKit
import Foundation
import Testing
@testable import BasilRemote

/// macOS's own Apache httpd with mod_dav, run as the test user on free ports of 127.0.0.1 from
/// a throwaway configuration, and stopped when the test process exits. One folder is served
/// three times: /dav with a Basic login, /digest with a Digest login and /open without one,
/// over HTTP on `port` and over HTTPS (a self-signed "localhost" certificate) on `tlsPort`.
/// Tests check results in `files` with FileManager.
final class WebDAVTestServer: Sendable {
    static let shared: WebDAVTestServer? = try? WebDAVTestServer()

    let folder: URL
    /// What /dav, /digest and /open serve.
    let files: URL
    let port: Int
    let tlsPort: Int
    let user = "alice"
    let password = "open sesame"

    init() throws {
        let httpd = "/usr/sbin/httpd"
        guard FileManager.default.isExecutableFile(atPath: httpd) else { throw VFSError.failed("no httpd") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-httpd-\(UUID().uuidString.prefix(8))")
        files = folder.appendingPathComponent("files")
        let top = folder.appendingPathComponent("top")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        let path = folder.path
        TestServer.folders.withLock { $0.append(path) }
        port = TestServer.freePort()
        var tls = TestServer.freePort()
        while tls == port { tls = TestServer.freePort() }
        tlsPort = tls

        let key = folder.appendingPathComponent("key.pem")
        let crt = folder.appendingPathComponent("crt.pem")
        try TestServer.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                                                "-subj", "/CN=localhost", "-keyout", key.path, "-out", crt.path])
        let basic = "\(user):{SHA}" + Data(Insecure.SHA1.hash(data: Data(password.utf8))).base64EncodedString() + "\n"
        try basic.write(to: folder.appendingPathComponent("users.basic"), atomically: true, encoding: .utf8)
        let realm = "Basil digest"
        let ha1 = Insecure.MD5.hash(data: Data("\(user):\(realm):\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
        try "\(user):\(realm):\(ha1)\n".write(to: folder.appendingPathComponent("users.digest"), atomically: true, encoding: .utf8)

        let modules = ["mpm_prefork", "authn_file", "authn_core", "authz_user", "authz_core", "auth_basic",
                       "auth_digest", "dav", "dav_fs", "unixd", "ssl", "alias", "mime", "log_config"]
        let shares = """
        Alias /dav \(files.path)
        Alias /digest \(files.path)
        Alias /open \(files.path)
        <Directory \(files.path)>
          Dav On
          Options None
          AllowOverride None
        </Directory>
        <Location /dav>
          AuthType Basic
          AuthName "Basil test"
          AuthUserFile \(path)/users.basic
          Require valid-user
        </Location>
        <Location /digest>
          AuthType Digest
          AuthName "\(realm)"
          AuthDigestProvider file
          AuthUserFile \(path)/users.digest
          Require valid-user
        </Location>
        """
        let config = """
        ServerRoot "/usr"
        \(modules.map { "LoadModule \($0)_module libexec/apache2/mod_\($0).so" }.joined(separator: "\n"))
        Listen 127.0.0.1:\(port)
        Listen 127.0.0.1:\(tlsPort)
        ServerName localhost
        PidFile \(path)/httpd.pid
        Mutex file:\(path) default
        ErrorLog \(path)/error.log
        LogFormat "%r %>s" basil
        CustomLog \(path)/access.log basil
        DavLockDB \(path)/davlock
        DocumentRoot \(top.path)
        StartServers 2
        MaxRequestWorkers 20
        LimitRequestBody 0
        \(shares)
        <VirtualHost 127.0.0.1:\(tlsPort)>
          SSLEngine on
          SSLCertificateFile \(crt.path)
          SSLCertificateKeyFile \(key.path)
        </VirtualHost>
        """
        let configFile = folder.appendingPathComponent("httpd.conf")
        try config.write(to: configFile, atomically: true, encoding: .utf8)
        try TestServer.start(httpd, ["-f", configFile.path, "-D", "FOREGROUND"], log: folder.appendingPathComponent("httpd.out"))
        let port = port
        try TestServer.waitFor {
            (try? SSHConnection.connectSocket(host: "127.0.0.1", port: port, timeout: 200)).map { close($0); return true } ?? false
        }
    }

    /// A fresh folder below the served one; its server path is "/dav/<name>" (or /digest, /open).
    func sandbox() throws -> (name: String, url: URL) {
        let name = "t-" + UUID().uuidString.prefix(8)
        let url = files.appendingPathComponent(String(name))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (String(name), url)
    }

    func target(secure: Bool = false, share: String = "dav", folder name: String, user: String? = nil) -> RemoteTarget {
        RemoteTarget(service: secure ? .webdavs : .webdav, host: "127.0.0.1", port: secure ? tlsPort : port,
                     user: user ?? self.user, path: "/\(share)/\(name)", authentication: .password)
    }
}

/// The official Nextcloud image, run through Docker (OrbStack) as the container
/// "basil-test-nextcloud" on a free port with an SQLite database. The first start installs
/// Nextcloud (about a minute); the container is stopped when the tests end and started again
/// next time. nil when Docker is not running.
final class NextcloudTestServer: Sendable {
    static let shared: NextcloudTestServer? = try? NextcloudTestServer()

    static let container = "basil-test-nextcloud"
    let port: Int
    let user = "alice"
    let password = "Basil-test-pw-1"

    init() throws {
        let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                      NSHomeDirectory() + "/.orbstack/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker, (try? Self.output(docker, ["info", "--format", "{{.ServerVersion}}"])) != nil else {
            throw VFSError.failed("Docker is not running")
        }
        let existing = try? Self.output(docker, ["port", Self.container, "80/tcp"])
        if let existing, let found = existing.split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            port = found
            _ = try? Self.output(docker, ["start", Self.container])
        } else if (try? Self.output(docker, ["inspect", Self.container])) != nil {
            // Made before but its port is unknown while stopped: start it and ask again.
            _ = try Self.output(docker, ["start", Self.container])
            let text = try Self.output(docker, ["port", Self.container, "80/tcp"])
            guard let found = text.split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
                throw VFSError.failed("Nextcloud container has no port")
            }
            port = found
        } else {
            port = TestServer.freePort()
            _ = try Self.output(docker, [
                "run", "-d", "--name", Self.container, "-p", "127.0.0.1:\(port):80",
                "-e", "SQLITE_DATABASE=nextcloud", "-e", "NEXTCLOUD_ADMIN_USER=\(user)",
                "-e", "NEXTCLOUD_ADMIN_PASSWORD=\(password)", "-e", "NEXTCLOUD_TRUSTED_DOMAINS=127.0.0.1 localhost",
                "nextcloud:stable",
            ])
        }
        atexit {
            let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            if let docker { _ = try? NextcloudTestServer.output(docker, ["stop", "-t", "2", NextcloudTestServer.container]) }
        }
        // Installed and answering WebDAV.
        let status = URL(string: "http://127.0.0.1:\(port)/status.php")!
        for _ in 0..<180 {
            if let data = try? Data(contentsOf: status), String(decoding: data, as: UTF8.self).contains("\"installed\":true") {
                return
            }
            usleep(1_000_000)
        }
        throw VFSError.failed("Nextcloud did not start")
    }

    static func output(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VFSError.failed("\(tool) \(arguments.first ?? "") failed") }
        return String(decoding: data, as: UTF8.self)
    }

    func target(path: String? = nil) -> RemoteTarget {
        RemoteTarget(service: .webdav, host: "127.0.0.1", port: port, user: user, path: path, authentication: .password)
    }
}

/// ownCloud 10 (the owncloud/server image) through Docker as "basil-test-owncloud", like the
/// Nextcloud one: SQLite, user alice, on a free port; stopped when the tests end. nil when
/// Docker is not running.
final class OwnCloudTestServer: Sendable {
    static let shared: OwnCloudTestServer? = try? OwnCloudTestServer()

    static let container = "basil-test-owncloud"
    let port: Int
    let user = "alice"
    let password = "Basil-test-pw-1"

    init() throws {
        let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                      NSHomeDirectory() + "/.orbstack/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker, (try? NextcloudTestServer.output(docker, ["info", "--format", "{{.ServerVersion}}"])) != nil else {
            throw VFSError.failed("Docker is not running")
        }
        func parsePort(_ text: String) -> Int? {
            text.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if (try? NextcloudTestServer.output(docker, ["inspect", Self.container])) != nil {
            _ = try NextcloudTestServer.output(docker, ["start", Self.container])
            guard let found = parsePort(try NextcloudTestServer.output(docker, ["port", Self.container, "8080/tcp"])) else {
                throw VFSError.failed("ownCloud container has no port")
            }
            self.port = found
        } else {
            let free = TestServer.freePort()
            self.port = free
            _ = try NextcloudTestServer.output(docker, [
                "run", "-d", "--name", Self.container, "-p", "127.0.0.1:\(free):8080",
                "-e", "OWNCLOUD_DOMAIN=127.0.0.1:\(free)", "-e", "OWNCLOUD_TRUSTED_DOMAINS=127.0.0.1,localhost",
                "-e", "OWNCLOUD_ADMIN_USERNAME=\(user)", "-e", "OWNCLOUD_ADMIN_PASSWORD=\(password)",
                "owncloud/server:10.15",
            ])
        }
        atexit {
            let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            if let docker { _ = try? NextcloudTestServer.output(docker, ["stop", "-t", "2", OwnCloudTestServer.container]) }
        }
        let status = URL(string: "http://127.0.0.1:\(port)/status.php")!
        for _ in 0..<240 {
            if let data = try? Data(contentsOf: status), String(decoding: data, as: UTF8.self).contains("\"installed\":true") {
                return
            }
            usleep(1_000_000)
        }
        throw VFSError.failed("ownCloud did not start")
    }

    func target(path: String? = nil) -> RemoteTarget {
        RemoteTarget(service: .webdav, host: "127.0.0.1", port: port, user: user, path: path, authentication: .password)
    }
}
