import AppKit
import UniformTypeIdentifiers

/// Opens local files in the user's editor (Shift+F4). The editor is an app chosen in Settings,
/// or the system default app for the file. Files no app claims (an unknown extension) open in
/// TextEdit. Per-extension editor lists come with F4 (M3).
@MainActor
public enum EditorLauncher {
    public static let fallbackEditorBundleID = "com.apple.TextEdit"

    /// Opens `file` in the editor at `editorAppPath`, or in the default app when it is nil.
    public static func open(_ file: URL, editorAppPath: String?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: URL
        if let editorAppPath {
            app = URL(fileURLWithPath: editorAppPath)
        } else if let handler = NSWorkspace.shared.urlForApplication(toOpen: file) {
            app = handler
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackEditorBundleID) {
            app = textEdit
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }

    /// The app's display name ("TextEdit") for a path to an .app bundle.
    public static func displayName(ofApp path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The apps that can open a file, and changing the system default app for its type
/// (what Finder's Get Info "Change All" does).
@MainActor
public enum FileAssociations {
    public struct App: Hashable, Sendable, Identifiable {
        public let url: URL
        public let name: String
        public var id: URL { url }
    }

    /// The default app first, then the others sorted by name, without duplicates.
    public static func apps(toOpen file: URL) -> (defaultApp: App?, all: [App]) {
        func app(_ url: URL) -> App { App(url: url, name: EditorLauncher.displayName(ofApp: url.path)) }
        let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: file)
        var seen = Set<String>()
        var others: [App] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: file) where url != defaultURL {
            if seen.insert(url.standardizedFileURL.path).inserted { others.append(app(url)) }
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let defaultApp = defaultURL.map(app)
        return (defaultApp, (defaultApp.map { [$0] } ?? []) + others)
    }

    /// The type that "all files like this one" means: from the extension, or the file's own type.
    public static func contentType(of file: URL) -> UTType? {
        if !file.pathExtension.isEmpty, let type = UTType(filenameExtension: file.pathExtension) { return type }
        return try? file.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    /// Makes `app` the system-wide default for every file of `type`.
    public static func setDefault(_ app: URL, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }
}
