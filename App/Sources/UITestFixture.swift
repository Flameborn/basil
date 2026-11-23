#if DEBUG
import BasilCore
import BasilRemote
import CryptoKit
import Foundation

/// Debug-only: when launched with BASIL_UITEST_FIXTURE=1, builds a known directory tree and
/// starts both panes in it. Needed because Xcode sandboxes the UI-test runner, so files it
/// creates live in its container, which other apps (Basil) are not allowed to read.
enum UITestFixture {
    static var isActive: Bool { ProcessInfo.processInfo.environment["BASIL_UITEST_FIXTURE"] == "1" }

    /// A separate preferences domain, wiped at each launch, so tests never touch the user's settings.
    static func isolatedDefaults() -> UserDefaults? {
        guard isActive else { return nil }
        let suite = "com.flameborn.basil.uitests"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)
    }

    /// With BASIL_UITEST_LEFTOVERS=1: where the fake app's leftovers are (home, /Library, /var/folders, receipts).
    nonisolated(unsafe) static var leftoverPlaces: URL?

    /// Beta/Leftie.app (bundle ID com.example.BasilLeftie) and three leftovers of it in a fake home.
    private static func makeLeftovers(app: URL, places: URL) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.BasilLeftie", "CFBundleName": "Leftie",
                                   "CFBundleExecutable": "Leftie", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/Leftie"))
        for path in ["home/Library/Preferences/com.example.BasilLeftie.plist",
                     "home/Library/Caches/com.example.BasilLeftie/cache.db",
                     "var/T/com.example.BasilLeftie/scratch"] {
            let url = places.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createDirectory(at: places.appendingPathComponent("var/C"), withIntermediateDirectories: true)
        leftoverPlaces = places
    }

    static func makeIfRequested() -> (left: VFSPath, right: VFSPath)? {
        guard ProcessInfo.processInfo.environment["BASIL_UITEST_FIXTURE"] == "1" else { return nil }
        let fm = FileManager.default
        // XCUIApplication.terminate() kills the app without applicationWillTerminate,
        // so remove fixtures left by earlier runs first.
        let temp = fm.temporaryDirectory
        for old in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where old.hasPrefix("basil-uitest-") {
            try? fm.removeItem(at: temp.appendingPathComponent(old))
        }
        let root = temp.appendingPathComponent("basil-uitest-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try fm.createDirectory(at: root.appendingPathComponent("Alpha/Inner"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("Beta"), withIntermediateDirectories: true)
            for name in ["apple pie.txt", "song.mp3", "track.flac", "notes.md", ".secret"] {
                try Data("x".utf8).write(to: root.appendingPathComponent(name))
            }
            try makeZip(at: root.appendingPathComponent("Alpha/Inner/pack.zip"))
            if ProcessInfo.processInfo.environment["BASIL_UITEST_ENCRYPTED_7Z"] == "1" {
                try makeEncrypted7z(at: root.appendingPathComponent("Alpha/Inner/secret.7z"))
            }
            if ProcessInfo.processInfo.environment["BASIL_UITEST_LEFTOVERS"] == "1" {
                try makeLeftovers(app: root.appendingPathComponent("Beta/Leftie.app"),
                                  places: temp.appendingPathComponent("basil-uitest-leftovers-\(ProcessInfo.processInfo.processIdentifier)"))
            }
            if ProcessInfo.processInfo.environment["BASIL_UITEST_RAR"] == "1" {
                try Data(base64Encoded: rar4Archive.joined())!.write(to: root.appendingPathComponent("Alpha/Inner/old.rar"))
            }
        } catch {
            return nil
        }
        createdRoot = root
        return (.local(root.path), .local(root.appendingPathComponent("Beta").path))
    }

    /// Alpha/Inner/pack.zip with docs/readme.txt and top.txt, made with the system zip tool.
    private static func makeZip(at url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("basil-uitest-zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: staging.appendingPathComponent("docs/readme.txt"))
        try Data("top".utf8).write(to: staging.appendingPathComponent("top.txt"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.path, "docs", "top.txt"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
    }

    /// Alpha/Inner/secret.7z with note.txt, names and data encrypted with the password "basil",
    /// made with the bundled 7zz (the password goes in through stdin).
    private static func makeEncrypted7z(at url: URL) throws {
        let fm = FileManager.default
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "7zz") else { throw CocoaError(.fileNoSuchFile) }
        let staging = fm.temporaryDirectory.appendingPathComponent("basil-uitest-7z-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: staging.appendingPathComponent("note.txt"))
        let sevenZip = Process()
        sevenZip.executableURL = tool
        sevenZip.arguments = ["a", "-p", "-mhe=on", url.path, "note.txt"]
        sevenZip.currentDirectoryURL = staging
        let input = Pipe()
        sevenZip.standardInput = input
        sevenZip.standardOutput = FileHandle.nullDevice
        try sevenZip.run()
        try input.fileHandleForWriting.write(contentsOf: Data("basil\n".utf8))
        try input.fileHandleForWriting.close()
        sevenZip.waitUntilExit()
    }

    /// Alpha/Inner/old.rar: libarchive's test_read_format_rar.rar (RAR 4; test.txt, testdir with
    /// test.txt, testemptydir, and testlink pointing to test.txt). Nothing on macOS makes RAR archives.
    private static let rar4Archive = [
        "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRl",
        "c3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0",
        "LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQg",
        "ZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAA",
        "AAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA",
    ]

    nonisolated(unsafe) private static var createdRoot: URL?

    static func cleanup() {
        if let root = createdRoot { try? FileManager.default.removeItem(at: root) }
    }
}
#endif

#if DEBUG
/// BASIL_UITEST_SSHD=1: an OpenSSH sshd for the UI tests, run by the app (the test runner is
/// sandboxed) on a free port of 127.0.0.1 with throwaway keys, serving this Mac's files. The app
/// connects with its own known_hosts and ssh config, never the user's. A watchdog shell stops
/// sshd when the app goes away (XCUIApplication.terminate kills it without notice).
enum UITestSSHServer {
    struct Server {
        let port: Int
        let key: String
        let home: URL
        let knownHosts: URL
    }

    static func startIfRequested() -> Server? {
        guard UITestFixture.isActive, ProcessInfo.processInfo.environment["BASIL_UITEST_SSHD"] == "1" else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-uitest-sshd-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: folder)
        let home = folder.appendingPathComponent("home")
        do {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let hostKey = folder.appendingPathComponent("host_ed25519").path
            let key = folder.appendingPathComponent("client").path
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
            try FileManager.default.copyItem(atPath: key + ".pub", toPath: folder.appendingPathComponent("authorized_keys").path)
            let port = freePort()
            try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey)
            AuthorizedKeysFile \(folder.path)/authorized_keys
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            PidFile \(folder.path)/sshd.pid
            PerSourcePenalties no
            Subsystem sftp internal-sftp
            """.write(to: folder.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
            let sshd = Process()
            sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            sshd.arguments = ["-D", "-e", "-f", folder.appendingPathComponent("sshd_config").path]
            sshd.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try sshd.run()
            let watchdog = Process()
            watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
            watchdog.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done; kill \(sshd.processIdentifier); rm -rf '\(folder.path)'"]
            try watchdog.run()
            for _ in 0..<100 where !accepts(port) { usleep(50_000) }
            return Server(port: port, key: key, home: home, knownHosts: home.appendingPathComponent(".ssh/known_hosts"))
        } catch {
            return nil
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
#endif

#if DEBUG
/// pure-ftpd for the FTP UI test (`BASIL_UITEST_FTPD` = the folder scripts/build-test-ftpd.sh
/// builds into). Explicit TLS with a self-signed certificate, one account (`user`, `password`)
/// without a chroot. Stopped by a watchdog when the app ends.
enum UITestFTPServer {
    struct Server {
        let port: Int
        let user = "basil"
        let password = "ftp secret"
    }

    static func startIfRequested() -> Server? {
        guard UITestFixture.isActive, let tools = ProcessInfo.processInfo.environment["BASIL_UITEST_FTPD"] else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-uitest-ftpd-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let key = folder.appendingPathComponent("key.pem").path
            let crt = folder.appendingPathComponent("crt.pem").path
            try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                                         "-subj", "/CN=localhost", "-keyout", key, "-out", crt])
            let certificate = folder.appendingPathComponent("cert.pem")
            try (String(contentsOfFile: key, encoding: .utf8) + String(contentsOfFile: crt, encoding: .utf8))
                .write(to: certificate, atomically: true, encoding: .utf8)
            let server = Server(port: freePort())
            let pdb = folder.appendingPathComponent("pureftpd.pdb").path
            let pw = Process()
            pw.executableURL = URL(fileURLWithPath: tools + "/pure-pw")
            pw.arguments = ["useradd", server.user, "-u", "\(getuid())", "-g", "\(getgid())", "-D", folder.path,
                            "-f", folder.appendingPathComponent("passwd").path, "-F", pdb, "-m"]
            let input = Pipe()
            pw.standardInput = input
            pw.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            try pw.run()
            input.fileHandleForWriting.write(Data("\(server.password)\n\(server.password)\n".utf8))
            try input.fileHandleForWriting.close()
            pw.waitUntilExit()
            let ftpd = Process()
            ftpd.executableURL = URL(fileURLWithPath: tools + "/pure-ftpd")
            ftpd.arguments = ["-S", "127.0.0.1,\(server.port)", "-l", "puredb:\(pdb)", "-E", "-z", "-H", "-Y", "1",
                              "-2", certificate.path, "-p", "42000:42999"]
            ftpd.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try ftpd.run()
            let watchdog = Process()
            watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
            watchdog.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done; kill \(ftpd.processIdentifier); rm -rf '\(folder.path)'"]
            try watchdog.run()
            for _ in 0..<100 where !UITestSSHServer.accepts(server.port) { usleep(50_000) }
            return server
        } catch {
            return nil
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
    }

    private static func freePort() -> Int { UITestSSHServer.freePort() }
}

/// macOS's own Apache httpd for the WebDAV UI test (`BASIL_UITEST_WEBDAV=1`): HTTPS on a free
/// port with a self-signed certificate and a Basic login, serving `folder` (the fixture) at
/// /dav. A watchdog stops it when the app dies.
enum UITestWebDAVServer {
    struct Server {
        let port: Int
        let user = "basil"
        let password = "dav secret"
    }

    static func startIfRequested(serving served: String) -> Server? {
        guard UITestFixture.isActive, ProcessInfo.processInfo.environment["BASIL_UITEST_WEBDAV"] == "1",
              FileManager.default.isExecutableFile(atPath: "/usr/sbin/httpd") else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-uitest-httpd-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: folder)
        do {
            let top = folder.appendingPathComponent("top")
            try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
            let key = folder.appendingPathComponent("key.pem").path
            let crt = folder.appendingPathComponent("crt.pem").path
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                                 "-subj", "/CN=localhost", "-keyout", key, "-out", crt]
            openssl.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try openssl.run()
            openssl.waitUntilExit()
            let server = Server(port: UITestSSHServer.freePort())
            let users = folder.appendingPathComponent("users").path
            // {SHA}: base64 of the SHA-1 of the password, as htpasswd -s writes it.
            let digest = Insecure.SHA1.hash(data: Data(server.password.utf8))
            try "\(server.user):{SHA}\(Data(digest).base64EncodedString())\n".write(toFile: users, atomically: true, encoding: .utf8)
            let modules = ["mpm_prefork", "authn_file", "authn_core", "authz_user", "authz_core", "auth_basic",
                           "dav", "dav_fs", "unixd", "ssl", "alias", "mime", "log_config"]
            let config = """
            ServerRoot "/usr"
            \(modules.map { "LoadModule \($0)_module libexec/apache2/mod_\($0).so" }.joined(separator: "\n"))
            Listen 127.0.0.1:\(server.port)
            ServerName localhost
            PidFile \(folder.path)/httpd.pid
            Mutex file:\(folder.path) default
            ErrorLog \(folder.path)/error.log
            DavLockDB \(folder.path)/davlock
            DocumentRoot \(top.path)
            SSLEngine on
            SSLCertificateFile \(crt)
            SSLCertificateKeyFile \(key)
            Alias /dav \(served)
            <Directory \(served)>
              Dav On
              AuthType Basic
              AuthName "Basil UI test"
              AuthUserFile \(users)
              Require valid-user
            </Directory>
            """
            let configFile = folder.appendingPathComponent("httpd.conf").path
            try config.write(toFile: configFile, atomically: true, encoding: .utf8)
            let httpd = Process()
            httpd.executableURL = URL(fileURLWithPath: "/usr/sbin/httpd")
            httpd.arguments = ["-f", configFile, "-D", "FOREGROUND"]
            httpd.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try httpd.run()
            let watchdog = Process()
            watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
            watchdog.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done; kill \(httpd.processIdentifier); rm -rf '\(folder.path)'"]
            try watchdog.run()
            for _ in 0..<100 where !UITestSSHServer.accepts(server.port) { usleep(50_000) }
            return server
        } catch {
            return nil
        }
    }
}
/// The Samba container of the BasilRemote tests (`basil-test-samba`, made by their first run)
/// for the SMB UI test (`BASIL_UITEST_SMB=1`): started when Docker (OrbStack) runs, stopped
/// again by a watchdog when the app dies. The share media is emptied first.
enum UITestSMBServer {
    struct Server {
        let host: String
        let user = "alice"
    }

    static let container = "basil-test-samba"

    static func startIfRequested() -> Server? {
        guard UITestFixture.isActive, ProcessInfo.processInfo.environment["BASIL_UITEST_SMB"] == "1",
              let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              run(docker, ["start", container]) != nil,
              let host = run(docker, ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        for _ in 0..<200 where !answers(host) { usleep(100_000) }
        _ = run(docker, ["exec", container, "sh", "-c", "rm -rf /shares/media/*"])
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done; '\(docker)' stop -t 2 \(container)"]
        try? watchdog.run()
        return Server(host: host)
    }

    /// Whether the server accepts connections on the port yet (Samba: 445).
    static func answers(_ host: String, port: Int = 445) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        // Non-blocking with a short wait: a connect to an address that is not up yet can hang.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 200) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// The S3 gateway container of the BasilRemote tests (`basil-test-s3`, made by their first run)
/// for the S3 UI test (`BASIL_UITEST_S3=1`): started when Docker (OrbStack) runs, emptied (no
/// buckets), and stopped again by a watchdog when the app dies.
enum UITestS3Server {
    struct Server {
        let host: String
        let port = 7070
        let accessKey = "basil-test-key"
    }

    static let container = "basil-test-s3"

    static func startIfRequested() -> Server? {
        guard UITestFixture.isActive, ProcessInfo.processInfo.environment["BASIL_UITEST_S3"] == "1",
              let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              UITestSMBServer.run(docker, ["start", container]) != nil,
              let host = UITestSMBServer.run(docker, ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        let server = Server(host: host)
        for _ in 0..<100 where !UITestSMBServer.answers(host, port: server.port) { usleep(100_000) }
        _ = UITestSMBServer.run(docker, ["exec", container, "sh", "-c", "rm -rf /data/* /data/.[!.]*"])
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done; '\(docker)' stop -t 2 \(container)"]
        try? watchdog.run()
        return server
    }
}
#endif
