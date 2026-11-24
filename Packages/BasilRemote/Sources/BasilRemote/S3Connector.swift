import BasilCore
import BasilVFS
import Foundation

/// Connects to Amazon S3 and services that speak its protocol (Cloudflare R2, Backblaze B2,
/// Wasabi, MinIO, ...). One connection is an endpoint (Host) and a key. With Automatic, a User
/// that names a profile of ~/.aws/credentials or ~/.aws/config (empty: default) logs in with
/// that profile's keys; any other User is an access key ID, as with Password, and the secret
/// access key is asked for like a password (Keychain optional). The top folder lists the buckets; the Start folder may name a bucket and a
/// folder in it ("/photos/2026"), which keys limited to some buckets need. Each bucket's region
/// is learned from the server's answers.
public struct S3Connector: RemoteConnector {
    let trust: CertificateTrust
    let profiles: AWSProfiles

    public init(trustFile: URL) {
        trust = CertificateTrust(file: trustFile)
        profiles = AWSProfiles()
    }

    init(trustFile: URL, profiles: AWSProfiles) {
        trust = CertificateTrust(file: trustFile)
        self.profiles = profiles
    }

    public var service: ProviderID { .s3 }
    public var displayName: String { "S3" }
    public var defaultPort: Int { 443 }
    public var logins: [RemoteLogin] { [.automatic, .password] }
    public var automaticLoginTitle: String { "AWS profile or access key" }
    public var hostPlaceholder: String { "Endpoint, such as s3.amazonaws.com" }
    public var userPlaceholder: String { "Access key ID, or the AWS profile's name" }
    public var pathPlaceholder: String? { "Bucket and folder, such as /photos/2026 (empty: all buckets)" }
    public var loginNote: String? {
        "User is an access key ID (Basil asks for its secret access key) or the name of a profile in ~/.aws/credentials (empty: default). Password always takes User as the access key ID."
    }

    static let securityKey = "security"
    public var options: [RemoteOption] {
        [RemoteOption(key: Self.securityKey, title: "Connection",
                      kind: .choice([.init(value: "https", title: "HTTPS"),
                                     .init(value: "http", title: "HTTP (not encrypted)")], default: "https"),
                      help: "Use HTTP only for a server on your own network that has no HTTPS.")]
    }

    public func connect(_ target: RemoteTarget, prompts: any RemotePrompts) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let secure = target.option(Self.securityKey) != "http"
        let user = target.user?.trimmingCharacters(in: .whitespaces) ?? ""
        let startPath = "/" + (target.path ?? "").split(separator: "/").joined(separator: "/")
        let bucket = startPath.split(separator: "/").first.map(String.init)
        var host = target.host.trimmingCharacters(in: .whitespaces)
        var port = target.port

        let profileName = user.isEmpty ? "default" : user
        let profile = target.authentication == .automatic ? profiles.profile(profileName) : nil
        if target.authentication == .automatic, user.isEmpty, profile == nil {
            throw VFSError.failed("There is no default AWS profile in \(profiles.credentialsFile.path). Fill in User with an access key ID or a profile's name.")
        }
        if let profile {
            let name = profileName
            guard let accessKey = profile.accessKey, let secretKey = profile.secretKey else {
                if !profile.unsupported.isEmpty {
                    throw VFSError.failed("The AWS profile \(name) logs in with \(profile.unsupported.joined(separator: ", ")), which Basil cannot use. Give it aws_access_key_id and aws_secret_access_key, or log in with Password.")
                }
                throw VFSError.failed("The AWS profile \(name) has no aws_access_key_id and aws_secret_access_key")
            }
            if host.isEmpty, let url = profile.endpointURL.flatMap(URL.init(string:)), let named = url.host {
                host = named
                port = port ?? url.port
            }
            let endpoint = S3Endpoint(secure: secure, host: host.isEmpty ? "s3.amazonaws.com" : host,
                                      port: port ?? (secure ? 443 : 80), user: name)
            let credentials = S3Credentials(accessKey: accessKey, secretKey: secretKey, sessionToken: profile.sessionToken)
            let service = S3Service(endpoint: endpoint, credentials: credentials, region: profile.region)
            do {
                try await check(service, bucket: bucket, prompts: prompts)
            } catch let refused as KeysRefused {
                service.close()
                throw VFSError.failed("\(endpoint.hostAndPort) refused the keys of the AWS profile \(name): \(refused.message)")
            } catch {
                service.close()
                throw error
            }
            return try await finish(service, bucket: bucket, start: startPath)
        } else {
            guard !user.isEmpty else {
                throw VFSError.failed("Edit the connection and fill in User with the access key ID.")
            }
            let endpoint = S3Endpoint(secure: secure, host: host, port: port ?? (secure ? 443 : 80), user: user)
            var tries = 0
            while true {
                let request = SecretRequest(kind: .named("Secret access key"), account: endpoint.account, retry: tries > 0,
                                            keychainKey: "s3:\(endpoint.account)")
                guard let answer = await prompts.secret(request) else { throw RemoteCancelled() }
                let service = S3Service(endpoint: endpoint,
                                        credentials: S3Credentials(accessKey: user, secretKey: answer.secret.trimmingCharacters(in: .whitespaces)),
                                        region: nil)
                do {
                    try await check(service, bucket: bucket, prompts: prompts)
                } catch let refused as KeysRefused {
                    service.close()
                    tries += 1
                    if !refused.wrongSecret || tries == 3 {
                        throw VFSError.failed("\(endpoint.hostAndPort) refused the keys: \(refused.message)")
                    }
                    continue
                } catch {
                    service.close()
                    throw error
                }
                await prompts.secretWorked(request, answer)
                return try await finish(service, bucket: bucket, start: startPath)
            }
        }
    }

    private func finish(_ service: S3Service, bucket: String?, start: String) async throws
        -> (provider: any FileSystemProvider, start: VFSPath) {
        let provider = S3Provider(service: service, knownBuckets: bucket.map { [$0] } ?? [])
        let path = VFSPath(location: provider.location, path: start)
        if !path.isRoot {
            do {
                let item = try await provider.item(at: path)
                guard item.isDirectoryLike else { throw VFSError.notADirectory(path) }
            } catch {
                service.close()
                throw error
            }
        }
        return (provider, path)
    }

    /// The server refused the keys. `wrongSecret`: the access key is known, the secret is not
    /// right (worth asking again).
    struct KeysRefused: Error {
        var message: String
        var wrongSecret: Bool
    }

    /// Checks the keys with one request (listing the buckets, or the Start folder's bucket),
    /// asking about an untrusted certificate once.
    private func check(_ service: S3Service, bucket: String?, prompts: any RemotePrompts) async throws {
        let endpoint = service.endpoint
        var askedCertificate = false
        while true {
            let response: HTTPResponse
            do {
                if let bucket {
                    response = try await service.send("GET", bucket: bucket, query: [("list-type", "2"), ("max-keys", "0")])
                } else {
                    response = try await service.send("GET", bucket: nil)
                }
            } catch let untrusted as UntrustedCertificate {
                guard !askedCertificate else { throw VFSError.failed("\(endpoint.hostAndPort) sent another TLS certificate") }
                askedCertificate = true
                let digest = try await trust.verify(untrusted.chain, host: endpoint.host,
                                                    hostAndPort: endpoint.hostAndPort, prompts: prompts)
                service.http.accept(certificate: digest)
                continue
            }
            if response.isSuccess { return }
            let error = S3ErrorBody(response.body)
            switch error?.code ?? "" {
            case "SignatureDoesNotMatch":
                throw KeysRefused(message: "the secret access key is not right", wrongSecret: true)
            case "InvalidAccessKeyId":
                throw KeysRefused(message: "it does not know the access key ID \(service.credentials.accessKey)", wrongSecret: false)
            case "ExpiredToken", "InvalidToken":
                throw KeysRefused(message: "the session token has expired", wrongSecret: false)
            case "NoSuchBucket":
                throw VFSError.failed("\(endpoint.hostAndPort) has no bucket \(bucket ?? "")")
            case "AccessDenied" where bucket == nil:
                throw VFSError.failed("\(endpoint.hostAndPort) does not let these keys list the buckets. Put the bucket in the connection's Start folder (for example /photos).")
            case "AccessDenied":
                throw VFSError.failed("\(endpoint.hostAndPort) does not let these keys list the bucket \(bucket ?? "")")
            default:
                if let error {
                    throw VFSError.failed("\(endpoint.hostAndPort) refused the connection: \(error.message.isEmpty ? error.code : error.message) (\(error.code))")
                }
                if response.status == 403 { throw KeysRefused(message: "access denied", wrongSecret: true) }
                throw VFSError.failed("\(endpoint.hostAndPort) does not answer like an S3 service (HTTP \(response.status))")
            }
        }
    }
}

extension S3Connector {
    public func isUnencrypted(_ target: RemoteTarget) -> Bool { target.option(Self.securityKey) == "http" }
}
