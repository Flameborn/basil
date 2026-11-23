import BasilCore
import BasilVFS
import Darwin
import Foundation

/// The Versity S3 Gateway in Docker (OrbStack) as the container "basil-test-s3": an S3 service
/// that stores buckets as folders of /data in the container (posix backend), with one access
/// key. The tests connect to the container's address, port 7070, over HTTP. The container is
/// stopped when the tests end and started again next time. nil when Docker is not running.
final class S3TestServer: Sendable {
    static let shared: S3TestServer? = try? S3TestServer()

    static let container = "basil-test-s3"
    static let image = "versity/versitygw:latest"
    let host: String
    let port = 7070
    let accessKey = "basil-test-key"
    let secretKey = "Basil-test-secret-1"

    init() throws {
        let docker = try SMBTestServer.docker()
        if (try? SMBTestServer.output(docker, ["inspect", Self.container])) != nil {
            _ = try SMBTestServer.output(docker, ["start", Self.container])
        } else {
            _ = try SMBTestServer.output(docker, [
                "run", "-d", "--name", Self.container, "--entrypoint", "sh", Self.image, "-c",
                "mkdir -p /data && exec versitygw --access \(accessKey) --secret \(secretKey) posix /data",
            ])
        }
        atexit {
            if let docker = try? SMBTestServer.docker() {
                _ = try? SMBTestServer.output(docker, ["stop", "-t", "2", S3TestServer.container])
            }
        }
        let address = try SMBTestServer.output(docker, ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                                                        Self.container]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw VFSError.failed("The S3 container has no address") }
        host = address
        for _ in 0..<60 {
            if SMBTestServer.answers(host, port: port) { return }
            usleep(500_000)
        }
        throw VFSError.failed("The S3 gateway did not start")
    }

    /// A connection to the gateway over HTTP; `user` is the access key ID or a profile's name.
    func target(path: String? = nil, user: String? = nil, authentication: RemoteTarget.Authentication = .password) -> RemoteTarget {
        RemoteTarget(service: .s3, host: host, port: port, user: user ?? accessKey, path: path,
                     authentication: authentication, options: ["security": "http"])
    }
}
