import BasilCore
import BasilVFS
import Darwin
import Foundation

/// Samba in Docker (OrbStack) as the container "basil-test-samba" (Alpine with its samba
/// package, installed on the first start). Shares: files and media (user alice), open (guests
/// welcome). Server-side copy is on (fruit:copyfile), as on Windows servers. smbclient in the container plays another computer changing files. macOS's SMB client refuses servers on this Mac's own addresses, so the tests
/// connect to the container's address, which OrbStack routes to. The container is stopped when
/// the tests end and started again next time. nil when Docker is not running.
final class SMBTestServer: Sendable {
    static let shared: SMBTestServer? = try? SMBTestServer()

    static let container = "basil-test-samba"
    let host: String
    let user = "alice"
    let password = "Basil-test-pw-1"

    /// Runs as the container's command, so a restarted container sets itself up again quickly.
    static let setup = """
        set -e
        command -v smbclient >/dev/null || apk add --no-cache samba samba-client >/dev/null
        if ! id alice >/dev/null 2>&1; then
          adduser -D -H alice
          printf 'Basil-test-pw-1\\nBasil-test-pw-1\\n' | smbpasswd -a -s alice
        fi
        mkdir -p /shares/files /shares/media /shares/open
        chown -R alice /shares
        cat > /etc/samba/smb.conf <<CONF
        [global]
          server min protocol = SMB2
          map to guest = Bad User
          vfs objects = catia fruit streams_xattr
          fruit:metadata = stream
          fruit:copyfile = yes
        [files]
          path = /shares/files
          read only = no
          valid users = alice
        [media]
          path = /shares/media
          read only = no
          valid users = alice
        [open]
          path = /shares/open
          read only = no
          guest ok = yes
          force user = alice
        CONF
        exec smbd --foreground --no-process-group --debug-stdout
        """

    /// Raised whenever `setup` changes: a container made with an older setup is made again
    /// (a container keeps the command it was created with). 2: server-side copy (fruit:copyfile).
    static let setupVersion = "2"

    init() throws {
        let docker = try Self.docker()
        let label = try? Self.output(docker, ["inspect", "-f", "{{index .Config.Labels \"basil.setup\"}}", Self.container])
        if let label, label.trimmingCharacters(in: .whitespacesAndNewlines) != Self.setupVersion {
            _ = try Self.output(docker, ["rm", "-f", Self.container])
        }
        if label?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.setupVersion {
            _ = try Self.output(docker, ["start", Self.container])
        } else {
            _ = try Self.output(docker, ["run", "-d", "--name", Self.container, "--label", "basil.setup=\(Self.setupVersion)",
                                         "alpine:latest", "sh", "-c", Self.setup])
        }
        atexit {
            if let docker = try? SMBTestServer.docker() {
                _ = try? SMBTestServer.output(docker, ["stop", "-t", "2", SMBTestServer.container])
            }
        }
        let address = try Self.output(docker, ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                                               Self.container]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw VFSError.failed("The Samba container has no address") }
        host = address
        // The first start installs Samba.
        for _ in 0..<120 {
            if Self.answers(host, port: 445) { return }
            usleep(1_000_000)
        }
        throw VFSError.failed("Samba did not start")
    }

    static func docker() throws -> String {
        guard let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
            (try? output(docker, ["info", "--format", "{{.ServerVersion}}"])) != nil else {
            throw VFSError.failed("Docker is not running")
        }
        return docker
    }

    static func answers(_ host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func output(_ tool: String, _ arguments: [String]) throws -> String {
        try NextcloudTestServer.output(tool, arguments)
    }

    /// Runs a shell command in the container.
    func shell(_ command: String) throws {
        _ = try Self.output(Self.docker(), ["exec", Self.container, "sh", "-c", command])
    }

    /// Another SMB client changes a file of the share files: `make` builds its new content in
    /// /tmp/new from the current file ($F), then smbclient writes it over the file.
    func otherClient(_ path: String, make: String) throws {
        let share = path.split(separator: "/").first.map(String.init) ?? ""
        let inShare = path.split(separator: "/").dropFirst().joined(separator: "/")
        try shell("""
            F=/shares/\(share)/\(inShare); \(make) && \
            smbclient //localhost/\(share) -U \(user)%\(password) -c 'put /tmp/new \(inShare)' >/dev/null 2>&1
            """)
    }

    func target(path: String? = nil, user: String? = nil) -> RemoteTarget {
        RemoteTarget(service: .smb, host: host, port: nil, user: user ?? self.user, path: path,
                     authentication: .password)
    }
}
