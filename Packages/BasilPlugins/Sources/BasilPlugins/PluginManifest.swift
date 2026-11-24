import Foundation

/// What a plugin may reach beyond Basil's own providers and operations. Each one is asked for
/// once, when the plugin is first turned on, and remembered.
public enum PluginPermission: String, Codable, Sendable, CaseIterable, Comparable {
    /// basil.http: requests to any web address.
    case network
    /// basil.shell: commands run by /bin/sh as the user.
    case shell
    /// LuaJIT's ffi: C functions of any library, so everything the user's account can do.
    case ffi

    /// For the permission question and Settings.
    public var title: String {
        switch self {
        case .network: "Network access"
        case .shell: "Running shell commands"
        case .ffi: "LuaJIT's FFI (full access to your account)"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// plugin.json, read without running any of the plugin's code:
///
///     { "id": "com.example.wordcount", "name": "Word Count", "version": "1.0",
///       "description": "Counts words of text files.", "main": "main.lua",
///       "permissions": ["shell"] }
public struct PluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var author: String?
    /// The file run first (main.lua when missing).
    public var main: String?
    public var permissions: [PluginPermission]?

    public var entry: String { main ?? "main.lua" }
    public var wanted: Set<PluginPermission> { Set(permissions ?? []) }

    public init(id: String, name: String, version: String, description: String? = nil, author: String? = nil,
                main: String? = nil, permissions: [PluginPermission]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.main = main
        self.permissions = permissions
    }

    /// Reads and checks `folder/plugin.json`.
    public static func read(in folder: URL) throws -> PluginManifest {
        let file = folder.appendingPathComponent("plugin.json")
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw PluginError(message: "\(folder.lastPathComponent) has no plugin.json")
        }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch let error as DecodingError {
            throw PluginError(message: "plugin.json of \(folder.lastPathComponent) is not valid: \(Self.describe(error))")
        }
        guard manifest.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw PluginError(message: "plugin.json of \(folder.lastPathComponent): the id may only have letters, digits, dots, dashes and underscores")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError(message: "plugin.json of \(folder.lastPathComponent) has no name")
        }
        guard manifest.entry.hasSuffix(".lua"), !manifest.entry.contains(".."), !manifest.entry.hasPrefix("/") else {
            throw PluginError(message: "plugin.json of \(folder.lastPathComponent): main must be a .lua file in the plugin's folder")
        }
        return manifest
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "\(key.stringValue) is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".") + ": " + context.debugDescription
        @unknown default: "\(error)"
        }
    }
}
