import BasilVFS
import Foundation

/// One profile of the AWS command line tools, from ~/.aws/credentials and ~/.aws/config (or the
/// files AWS_SHARED_CREDENTIALS_FILE and AWS_CONFIG_FILE name).
struct AWSProfile: Sendable, Equatable {
    var name: String
    var accessKey: String?
    var secretKey: String?
    var sessionToken: String?
    var region: String?
    /// endpoint_url (also the one in an "s3 =" block), for S3-compatible services.
    var endpointURL: String?
    /// Settings that ask for a way to log in Basil does not offer (sso_start_url, role_arn,
    /// credential_process, ...).
    var unsupported: [String] = []
}

/// Reads the AWS command line tools' files. Values in credentials win over config.
struct AWSProfiles: Sendable {
    var credentialsFile: URL
    var configFile: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        func file(_ variable: String, _ fallback: String) -> URL {
            if let path = environment[variable], !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return home.appendingPathComponent(".aws").appendingPathComponent(fallback)
        }
        credentialsFile = file("AWS_SHARED_CREDENTIALS_FILE", "credentials")
        configFile = file("AWS_CONFIG_FILE", "config")
    }

    /// The profile, or nil when neither file has it.
    func profile(_ name: String) -> AWSProfile? {
        let credentials = Self.sections(of: credentialsFile)
        let config = Self.sections(of: configFile)
        // config names profiles "[profile name]", except "[default]".
        let configured = config[name == "default" ? "default" : "profile \(name)"]
            ?? (name == "default" ? config["profile default"] : nil)
        let stored = credentials[name]
        guard configured != nil || stored != nil else { return nil }
        let values = (configured ?? [:]).merging(stored ?? [:]) { $1 }
        var profile = AWSProfile(name: name)
        profile.accessKey = values["aws_access_key_id"]
        profile.secretKey = values["aws_secret_access_key"]
        profile.sessionToken = values["aws_session_token"]
        profile.region = values["region"]
        profile.endpointURL = values["s3.endpoint_url"] ?? values["endpoint_url"]
        profile.unsupported = ["sso_start_url", "sso_session", "role_arn", "credential_process", "web_identity_token_file", "source_profile"]
            .filter { values[$0] != nil }
        return profile
    }

    /// The names of every profile in either file.
    func names() -> [String] {
        var names = Set(Self.sections(of: credentialsFile).keys)
        for key in Self.sections(of: configFile).keys {
            if key == "default" { names.insert(key) } else if key.hasPrefix("profile ") { names.insert(String(key.dropFirst(8))) }
        }
        return names.sorted()
    }

    /// The INI sections of a file: name -> key -> value. A nested block ("s3 =" followed by
    /// indented lines) gives keys like "s3.endpoint_url".
    static func sections(of file: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        return sections(text)
    }

    static func sections(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        var block: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let name = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                current = name
                block = nil
                if result[name] == nil { result[name] = [:] }
                continue
            }
            guard let section = current, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let indented = line.first == " " || line.first == "\t"
            if indented, let block {
                result[section]?["\(block).\(key)"] = value
            } else if value.isEmpty {
                block = key
            } else {
                block = nil
                result[section]?[key] = value
            }
        }
        return result
    }
}
