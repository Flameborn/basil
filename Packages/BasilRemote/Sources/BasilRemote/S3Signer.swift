import CryptoKit
import Foundation

/// The keys an S3 connection signs its requests with.
struct S3Credentials: Sendable, Equatable {
    var accessKey: String
    var secretKey: String
    /// Temporary credentials (an AWS profile with aws_session_token).
    var sessionToken: String?
}

/// AWS Signature Version 4 for S3 (the Authorization header). Every request signs host,
/// x-amz-date, x-amz-content-sha256 and any other x-amz-* header; the payload hash is the SHA-256
/// of the body, so the server refuses a body that changed on the way.
enum S3Signer {
    static let emptyHash = sha256Hex(Data())

    /// The headers to add to a request: x-amz-date, x-amz-content-sha256, the session token when
    /// there is one, and Authorization. `path` and `query` are exactly as they go into the URL
    /// (already encoded, the query sorted); `host` is the Host header ("bucket.s3.amazonaws.com",
    /// "minio.local:9000").
    static func sign(method: String, host: String, path: String, query: String, headers: [String: String],
                     payloadHash: String, credentials: S3Credentials, region: String, date: Date = Date())
        -> [String: String] {
        let stamp = timestamp(date)
        let day = String(stamp.prefix(8))
        var added: [String: String] = ["x-amz-date": stamp, "x-amz-content-sha256": payloadHash]
        if let token = credentials.sessionToken, !token.isEmpty { added["x-amz-security-token"] = token }

        var signed: [String: String] = ["host": host]
        for (name, value) in headers.merging(added, uniquingKeysWith: { $1 }) {
            let lower = name.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "range" || lower == "content-md5" {
                signed[lower] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [method, path.isEmpty ? "/" : path, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, sha256Hex(Data(canonical.utf8))].joined(separator: "\n")

        var key = hmac(Data("AWS4\(credentials.secretKey)".utf8), day)
        key = hmac(key, region)
        key = hmac(key, "s3")
        key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, toSign))
        added["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return added
    }

    /// "20130524T000000Z"
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func hmac(_ key: Data, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }

    /// RFC 3986 encoding as SigV4 wants it: everything but A-Z a-z 0-9 - . _ ~ as %XX (upper
    /// case); "/" kept when `keepSlash` (object keys in a path).
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var result = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) || (keepSlash && byte == 0x2F) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    /// The query string as SigV4 and the URL both use it: names and values encoded, sorted by
    /// name, "name=" for empty values.
    static func query(_ items: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = items.map { (encode($0.0), encode($0.1)) }
        let sorted = encoded.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
    }
}
