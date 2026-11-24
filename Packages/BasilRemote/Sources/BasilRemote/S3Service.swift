import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Where one S3 connection goes.
struct S3Endpoint: Sendable {
    var secure: Bool
    /// The service's host ("s3.amazonaws.com", "abc.r2.cloudflarestorage.com", "nas.local").
    var host: String
    var port: Int
    /// The access key ID or "profile name", for titles and the Keychain.
    var user: String

    var defaultPort: Int { secure ? 443 : 80 }

    /// "nas.local", or "nas.local:9000" off the default port.
    var hostAndPort: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? name : "\(name):\(port)"
    }

    /// "AKIA...@s3.amazonaws.com"
    var account: String { "\(user)@\(hostAndPort)" }

    var isAWS: Bool {
        let lower = host.lowercased()
        return lower == "amazonaws.com" || lower.hasSuffix(".amazonaws.com")
    }

    /// The region a host names, as the services build their host names; nil when it names
    /// none (the connection then starts with us-east-1 and learns each bucket's region from
    /// the server's answers).
    static func region(fromHost host: String) -> String? {
        let lower = host.lowercased()
        let parts = lower.split(separator: ".").map(String.init)
        if lower.hasSuffix(".r2.cloudflarestorage.com") { return "auto" }
        if lower.hasSuffix(".amazonaws.com") {
            // s3.amazonaws.com, s3.eu-central-1.amazonaws.com, s3-eu-west-1.amazonaws.com,
            // s3.dualstack.eu-central-1.amazonaws.com
            let inner = parts.dropLast(2).filter { $0 != "dualstack" }
            if inner == ["s3"] || inner == ["s3-external-1"] { return "us-east-1" }
            if let first = inner.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) {
                if inner[first].hasPrefix("s3-") { return String(inner[first].dropFirst(3)) }
                if first + 1 < inner.count { return inner[first + 1] }
            }
            return nil
        }
        if lower.hasSuffix(".backblazeb2.com") || lower.hasSuffix(".wasabisys.com") {
            // s3.us-west-004.backblazeb2.com, s3.eu-central-1.wasabisys.com, s3.wasabisys.com
            return parts.count > 3 && parts[0] == "s3" ? parts[1] : "us-east-1"
        }
        if lower.hasSuffix(".digitaloceanspaces.com"), parts.count >= 3 { return parts[parts.count - 3] }
        return nil
    }
}

/// Signed S3 requests over one `HTTPClient`. Remembers each bucket's region (learned from the
/// server's redirects and errors) and, on AWS, sends a bucket's requests to its regional host.
/// Buckets are addressed in the host on AWS ("bucket.s3.amazonaws.com") and in the path
/// elsewhere ("nas.local/bucket"), which every S3-compatible service takes.
final class S3Service: Sendable {
    let http: HTTPClient
    let endpoint: S3Endpoint
    let credentials: S3Credentials
    /// The region of requests that name no bucket, and of buckets not seen yet.
    let defaultRegion: String
    private let regions = Mutex<[String: String]>([:])

    init(endpoint: S3Endpoint, credentials: S3Credentials, region: String?) {
        self.endpoint = endpoint
        self.credentials = credentials
        defaultRegion = region ?? S3Endpoint.region(fromHost: endpoint.host) ?? "us-east-1"
        http = HTTPClient(endpoint: HTTPEndpoint(service: .s3, secure: endpoint.secure, host: endpoint.host,
                                                 port: endpoint.port, defaultPort: endpoint.defaultPort, user: ""))
    }

    func close() { http.close() }

    func region(for bucket: String?) -> String {
        guard let bucket else { return defaultRegion }
        return regions.withLock { $0[bucket] } ?? defaultRegion
    }

    func learn(region: String, for bucket: String) { regions.withLock { $0[bucket] = region } }

    /// The host name a bucket's requests go to.
    func host(for bucket: String?) -> String {
        var host = endpoint.host
        if endpoint.isAWS, let bucket, let known = regions.withLock({ $0[bucket] }),
           S3Endpoint.region(fromHost: host) != known, ["s3.amazonaws.com", "s3-external-1.amazonaws.com"].contains(host.lowercased()) {
            host = "s3.\(known).amazonaws.com"
        }
        if let bucket, usesVirtualHost(bucket) { host = "\(bucket).\(host)" }
        return host
    }

    /// AWS wants buckets in the host; names with dots would not match its certificate there.
    func usesVirtualHost(_ bucket: String) -> Bool { endpoint.isAWS && !bucket.contains(".") }

    /// Host header, URL path (encoded) and URL for a bucket and key ("" for the bucket itself).
    func address(bucket: String?, key: String, query: String) -> (hostHeader: String, path: String, url: URL) {
        let host = host(for: bucket)
        var path = "/"
        if let bucket {
            path = usesVirtualHost(bucket) ? "/" : "/" + S3Signer.encode(bucket) + (key.isEmpty ? "" : "/")
            path += S3Signer.encode(key, keepSlash: true)
        }
        let name = host.contains(":") ? "[\(host)]" : host
        let hostHeader = endpoint.port == endpoint.defaultPort ? name : "\(name):\(endpoint.port)"
        let url = URL(string: (endpoint.secure ? "https://" : "http://") + hostHeader + path + (query.isEmpty ? "" : "?" + query))!
        return (hostHeader, path, url)
    }

    /// Sends a signed request. A refusal that names another region for the bucket is sent
    /// once more, signed for that region.
    func send(_ method: String, bucket: String?, key: String = "", query: [(String, String)] = [],
              headers: [String: String] = [:], body: Data? = nil, retry: Bool = true) async throws -> HTTPResponse {
        let queryString = S3Signer.query(query)
        let payloadHash = body.map(S3Signer.sha256Hex) ?? S3Signer.emptyHash
        for attempt in 0..<2 {
            let region = region(for: bucket)
            let (hostHeader, path, url) = address(bucket: bucket, key: key, query: queryString)
            let signed = S3Signer.sign(method: method, host: hostHeader, path: path, query: queryString, headers: headers,
                                       payloadHash: payloadHash, credentials: credentials, region: region)
            let response = try await http.send(method, url, headers: headers.merging(signed) { $1 },
                                               body: body ?? (method == "PUT" || method == "POST" ? Data() : nil), retry: retry)
            if attempt == 0, let bucket, !response.isSuccess, let hint = Self.regionHint(response), hint != region {
                learn(region: hint, for: bucket)
                continue
            }
            return response
        }
        fatalError("unreachable")
    }

    /// A signed GET from `offset` on, handed out as it arrives.
    func download(bucket: String, key: String, from offset: Int64) -> HTTPDownload {
        let (hostHeader, path, url) = address(bucket: bucket, key: key, query: "")
        var headers: [String: String] = [:]
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        let signed = S3Signer.sign(method: "GET", host: hostHeader, path: path, query: "", headers: headers,
                                   payloadHash: S3Signer.emptyHash, credentials: credentials, region: region(for: bucket))
        return http.download(url, from: 0, headers: headers.merging(signed) { $1 })
    }

    /// A presigned download address for an object, valid for `seconds`.
    func presignedURL(bucket: String, key: String, seconds: Int) -> URL {
        let (hostHeader, path, _) = address(bucket: bucket, key: key, query: "")
        return S3Signer.presignedURL(scheme: endpoint.secure ? "https" : "http", host: hostHeader, path: path,
                                     credentials: credentials, region: region(for: bucket), expires: seconds)
    }

    /// The region an error answer points to.
    static func regionHint(_ response: HTTPResponse) -> String? {
        guard [301, 307, 400, 403].contains(response.status) else { return nil }
        if let header = response.header("x-amz-bucket-region"), !header.isEmpty { return header }
        return S3ErrorBody(response.body)?.region
    }
}

extension ProviderID {
    /// Amazon S3 and services that speak its protocol.
    public static let s3 = ProviderID("s3")
}
