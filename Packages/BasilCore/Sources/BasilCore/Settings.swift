import Foundation
import Observation

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: VFSPath

    public init(id: UUID = UUID(), name: String, path: VFSPath) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// All user settings. Decoding tolerates missing keys so new settings never break old files.
public struct BasilSettings: Codable, Equatable, Sendable {
    public var size = SizeFormat()
    public var date = DateFormatSettings()
    public var views: [ListView] = ListView.defaults
    /// Switching to a volume from the drive menu goes to its root instead of the last folder visited there.
    public var goToRootOnVolumeSwitch = false
    public var bookmarks: [Bookmark] = []
    /// Copying and moving: read the destination back and compare hashes (off by default).
    public var verifyCopies = false
    /// Automatic re-reads of a source that changes during a copy, before asking what to do.
    public var unstableSourceRetries = 3
    /// Secure copy and move (source-change detection, partial file, atomic rename). Off by default:
    /// copying then works like Total Commander, writing straight to the target.
    public var secureCopy = false
    /// Sound and speech for queue events.
    public var feedback = FeedbackSettings()
    /// Saved Multi-Rename settings.
    public var renamePresets: [RenamePreset] = []
    /// The app that edits files (Shift+F4 new file), as a path to an .app bundle. Nil = the system default app.
    public var editorAppPath: String?
    /// F4 editors per file pattern; the first matching rule wins, no match uses `editorAppPath`.
    public var editorRules: [EditorRule] = []
    /// "Open terminal here" (Cmd+Shift+T): the terminal's id in `TerminalCatalog` (BasilIntegrations).
    public var terminalID = "terminal"
    /// Shell command for the "custom" terminal; `{dir}` is replaced by the quoted folder path.
    public var terminalCommand = ""
    /// Store extended attributes, Finder tags and resource forks in zip and tar archives (like Finder).
    public var packMacMetadata = true
    /// The pack dialog starts with the format and level used last.
    public var packFormat = "zip"
    public var packLevel = "normal"
    /// "Test archive after packing" in the pack dialog, remembered (off at first).
    public var packTestAfter = false
    /// The Create Checksum Files dialog starts with the algorithm used last (an algorithm's raw value).
    public var checksumAlgorithm = "sha256"
    /// Changes to the built-in views applied to saved settings. 2: the Name column shows the
    /// extension and Full no longer shows the Ext column.
    public var viewsVersion = BasilSettings.currentViewsVersion
    public static let currentViewsVersion = 2

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BasilSettings()
        size = try c.decodeIfPresent(SizeFormat.self, forKey: .size) ?? d.size
        date = try c.decodeIfPresent(DateFormatSettings.self, forKey: .date) ?? d.date
        views = try c.decodeIfPresent([ListView].self, forKey: .views) ?? d.views
        goToRootOnVolumeSwitch = try c.decodeIfPresent(Bool.self, forKey: .goToRootOnVolumeSwitch) ?? d.goToRootOnVolumeSwitch
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? d.bookmarks
        verifyCopies = try c.decodeIfPresent(Bool.self, forKey: .verifyCopies) ?? d.verifyCopies
        unstableSourceRetries = try c.decodeIfPresent(Int.self, forKey: .unstableSourceRetries) ?? d.unstableSourceRetries
        secureCopy = try c.decodeIfPresent(Bool.self, forKey: .secureCopy) ?? d.secureCopy
        feedback = try c.decodeIfPresent(FeedbackSettings.self, forKey: .feedback) ?? d.feedback
        renamePresets = try c.decodeIfPresent([RenamePreset].self, forKey: .renamePresets) ?? d.renamePresets
        editorAppPath = try c.decodeIfPresent(String.self, forKey: .editorAppPath) ?? d.editorAppPath
        editorRules = try c.decodeIfPresent([EditorRule].self, forKey: .editorRules) ?? d.editorRules
        terminalID = try c.decodeIfPresent(String.self, forKey: .terminalID) ?? d.terminalID
        terminalCommand = try c.decodeIfPresent(String.self, forKey: .terminalCommand) ?? d.terminalCommand
        packMacMetadata = try c.decodeIfPresent(Bool.self, forKey: .packMacMetadata) ?? d.packMacMetadata
        packFormat = try c.decodeIfPresent(String.self, forKey: .packFormat) ?? d.packFormat
        packLevel = try c.decodeIfPresent(String.self, forKey: .packLevel) ?? d.packLevel
        packTestAfter = try c.decodeIfPresent(Bool.self, forKey: .packTestAfter) ?? d.packTestAfter
        checksumAlgorithm = try c.decodeIfPresent(String.self, forKey: .checksumAlgorithm) ?? d.checksumAlgorithm
        viewsVersion = try c.decodeIfPresent(Int.self, forKey: .viewsVersion) ?? 1
        if viewsVersion < 2, let full = views.firstIndex(where: { $0.id == ListView.full.id }) {
            for i in views[full].columns.indices where views[full].columns[i].id == .ext {
                views[full].columns[i].isVisible = false
            }
        }
        viewsVersion = Self.currentViewsVersion
        // Built-in views must always exist.
        for builtin in ListView.defaults where !views.contains(where: { $0.id == builtin.id }) {
            views.append(builtin)
        }
    }

    public func view(id: String) -> ListView {
        views.first { $0.id == id } ?? .full
    }

    public var formatters: DisplayFormatters { DisplayFormatters(size: size, date: date) }
}

/// The live settings, persisted as JSON in UserDefaults. Observable for SwiftUI; AppKit
/// code registers `onChange` handlers.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: BasilSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            formatters = settings.formatters
            for handler in handlers.values { handler(settings) }
        }
    }

    /// Rebuilt whenever size/date settings change.
    public private(set) var formatters: DisplayFormatters

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var handlers: [UUID: (BasilSettings) -> Void] = [:]

    public init(defaults: UserDefaults = .standard, key: String = "basil.settings") {
        self.defaults = defaults
        self.key = key
        let loaded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BasilSettings.self, from: $0) }
        let settings = loaded ?? BasilSettings()
        self.settings = settings
        self.formatters = settings.formatters
    }

    /// Returns a token; pass it to `removeHandler` to stop observing.
    @discardableResult
    public func onChange(_ handler: @escaping (BasilSettings) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func removeHandler(_ id: UUID) { handlers[id] = nil }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
