import Foundation

/// One F4 editor rule (Total Commander style): a pattern list such as "*.txt;*.md" and the apps
/// that edit matching files. Patterns use the quick-filter syntax (`NameFilter`): wildcards,
/// `;` between patterns, exclusions after `|`. One app opens directly; several apps show a menu.
public struct EditorRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var patterns: String
    /// Paths to .app bundles, in menu order.
    public var apps: [String]

    public init(id: UUID = UUID(), patterns: String, apps: [String] = []) {
        self.id = id
        self.patterns = patterns
        self.apps = apps
    }

    /// True when the patterns match `name`. An empty or invalid pattern list matches nothing.
    public func matches(_ name: String) -> Bool {
        guard let filter = try? NameFilter(patterns), !filter.isEmpty else { return false }
        return filter.matches(name)
    }
}

public enum EditorRules {
    /// The apps of the first rule that matches `name` and has apps, or nil (use the global editor).
    public static func apps(for name: String, in rules: [EditorRule]) -> [String]? {
        rules.first { !$0.apps.isEmpty && $0.matches(name) }?.apps
    }
}
