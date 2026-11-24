import Foundation
import Observation

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: VFSPath
    /// For a folder on a server: how to connect when the server is not connected (no secrets).
    public var target: RemoteTarget?

    public init(id: UUID = UUID(), name: String, path: VFSPath, target: RemoteTarget? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.target = target
    }
}

/// All user settings. Decoding tolerates missing keys so new settings never break old files.
public struct BasilSettings: Codable, Equatable, Sendable {
    public var size = SizeFormat()
    public var date = DateFormatSettings()
    public var views: [ListView] = ListView.defaults
    /// Switching to a volume from the drive menu goes to its root instead of the last folder visited there.
    public var goToRootOnVolumeSwitch = false
    /// The user's changes to the default keys (Settings, Keys), applied to the command registry.
    public var keyBindings: [KeyBindingOverride] = []
    /// Space on a folder also calculates its size, like Total Commander's option (off by default).
    public var spaceCalculatesFolderSizes = false
    public var bookmarks: [Bookmark] = []
    /// Saved remote connections (Cmd+K), in the user's order. Secrets are in the Keychain.
    public var connections: [SavedConnection] = []
    /// Unencrypted servers the user chose not to be warned about again ("ftp://host:21").
    public var unencryptedAccepted: [String] = []
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
    /// Commit window: push once the commit is made (remembered, off at first).
    public var gitPushAfterCommit = false
    /// The progress window (like Total Commander's) for running operations; on by default.
    public var showProgressWindow = true
    /// "Solid archive" (7z) in the pack dialog, remembered (on at first, like 7-Zip).
    public var packSolid = true
    /// "Encrypt file names" (7z, with a password) in the pack dialog, remembered (off at first).
    public var packEncryptNames = false
    /// The Create Checksum Files dialog starts with the algorithm used last (an algorithm's raw value).
    public var checksumAlgorithm = "sha256"
    /// Unpack dialog (Option+F9), remembered: extract into a folder named after the archive when
    /// it has several items at the top (on at first), the file mask, "Unpack folder paths" (on),
    /// and how "Delete archive after unpacking" deletes (the Trash at first). The delete box
    /// itself always starts off.
    public var unpackOwnFolder = true
    public var unpackMask = ""
    public var unpackPaths = true
    public var unpackDeletePermanently = false
    /// Split dialog, remembered: the size preset's id ("cd700", "custom"), the custom size as
    /// typed ("1 GB"), decimal units for it (1000) instead of binary (1024), and "Create SFV file".
    public var splitPreset = "cd700"
    public var splitCustomSize = "1 GB"
    public var splitDecimalUnits = false
    public var splitCreateSFV = true
    /// Look for a new release on GitHub at launch and once a day (on by default).
    public var checkForUpdates = true
    /// The version the user chose "Skip This Version" for; automatic checks do not offer it.
    public var skippedUpdateVersion: String?
    /// Keep Basil's own filename index of the startup disk for fast name searches (on by default).
    public var searchIndex = true
    /// Other volumes ticked for indexing in Settings, by identity (see `IndexedVolume`).
    public var indexedVolumes: [IndexedVolume] = []
    /// Colour themes made in Settings > Themes (Basil's own is not stored).
    public var customThemes: [ThemeDefinition] = []
    /// The theme in use (`ThemeDefinition.builtinID` for Basil's own).
    public var themeID = ThemeDefinition.builtinID
    /// Plugins by id: turned on or off, and the permissions the user granted.
    public var plugins: [String: PluginSetting] = [:]
    /// How long the last S3 link made with Copy Link worked (seconds; Copy Link offers it first).
    public var linkLifetimeSeconds = 86_400
    /// Hours between background rescans of indexed network volumes (they also rescan when mounted).
    public var networkIndexRescanHours = 6
    /// Changes to the built-in views applied to saved settings. 2: the Name column shows the
    /// extension and Full no longer shows the Ext column.
    public var viewsVersion = BasilSettings.currentViewsVersion
    public static let currentViewsVersion = 3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BasilSettings()
        size = try c.decodeIfPresent(SizeFormat.self, forKey: .size) ?? d.size
        date = try c.decodeIfPresent(DateFormatSettings.self, forKey: .date) ?? d.date
        views = try c.decodeIfPresent([ListView].self, forKey: .views) ?? d.views
        goToRootOnVolumeSwitch = try c.decodeIfPresent(Bool.self, forKey: .goToRootOnVolumeSwitch) ?? d.goToRootOnVolumeSwitch
        keyBindings = try c.decodeIfPresent([KeyBindingOverride].self, forKey: .keyBindings) ?? d.keyBindings
        spaceCalculatesFolderSizes = try c.decodeIfPresent(Bool.self, forKey: .spaceCalculatesFolderSizes) ?? d.spaceCalculatesFolderSizes
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? d.bookmarks
        connections = try c.decodeIfPresent([SavedConnection].self, forKey: .connections) ?? d.connections
        unencryptedAccepted = try c.decodeIfPresent([String].self, forKey: .unencryptedAccepted) ?? d.unencryptedAccepted
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
        gitPushAfterCommit = try c.decodeIfPresent(Bool.self, forKey: .gitPushAfterCommit) ?? d.gitPushAfterCommit
        showProgressWindow = try c.decodeIfPresent(Bool.self, forKey: .showProgressWindow) ?? d.showProgressWindow
        packSolid = try c.decodeIfPresent(Bool.self, forKey: .packSolid) ?? d.packSolid
        packEncryptNames = try c.decodeIfPresent(Bool.self, forKey: .packEncryptNames) ?? d.packEncryptNames
        checksumAlgorithm = try c.decodeIfPresent(String.self, forKey: .checksumAlgorithm) ?? d.checksumAlgorithm
        unpackOwnFolder = try c.decodeIfPresent(Bool.self, forKey: .unpackOwnFolder) ?? d.unpackOwnFolder
        unpackMask = try c.decodeIfPresent(String.self, forKey: .unpackMask) ?? d.unpackMask
        unpackPaths = try c.decodeIfPresent(Bool.self, forKey: .unpackPaths) ?? d.unpackPaths
        unpackDeletePermanently = try c.decodeIfPresent(Bool.self, forKey: .unpackDeletePermanently) ?? d.unpackDeletePermanently
        splitPreset = try c.decodeIfPresent(String.self, forKey: .splitPreset) ?? d.splitPreset
        splitCustomSize = try c.decodeIfPresent(String.self, forKey: .splitCustomSize) ?? d.splitCustomSize
        splitDecimalUnits = try c.decodeIfPresent(Bool.self, forKey: .splitDecimalUnits) ?? d.splitDecimalUnits
        splitCreateSFV = try c.decodeIfPresent(Bool.self, forKey: .splitCreateSFV) ?? d.splitCreateSFV
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        skippedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .skippedUpdateVersion) ?? d.skippedUpdateVersion
        searchIndex = try c.decodeIfPresent(Bool.self, forKey: .searchIndex) ?? d.searchIndex
        indexedVolumes = try c.decodeIfPresent([IndexedVolume].self, forKey: .indexedVolumes) ?? d.indexedVolumes
        customThemes = try c.decodeIfPresent([ThemeDefinition].self, forKey: .customThemes) ?? d.customThemes
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        plugins = try c.decodeIfPresent([String: PluginSetting].self, forKey: .plugins) ?? d.plugins
        linkLifetimeSeconds = try c.decodeIfPresent(Int.self, forKey: .linkLifetimeSeconds) ?? d.linkLifetimeSeconds
        networkIndexRescanHours = try c.decodeIfPresent(Int.self, forKey: .networkIndexRescanHours) ?? d.networkIndexRescanHours
        viewsVersion = try c.decodeIfPresent(Int.self, forKey: .viewsVersion) ?? 1
        if viewsVersion < 2, let full = views.firstIndex(where: { $0.id == ListView.full.id }) {
            for i in views[full].columns.indices where views[full].columns[i].id == .ext {
                views[full].columns[i].isVisible = false
            }
        }
        // 3: the Git column (shown only inside repositories) after Name in the saved Full view.
        if viewsVersion < 3, let full = views.firstIndex(where: { $0.id == ListView.full.id }),
           !views[full].columns.contains(where: { $0.id == .git }) {
            let after = (views[full].columns.firstIndex { $0.id == .name }).map { $0 + 1 } ?? 0
            views[full].columns.insert(ColumnSpec(.git), at: after)
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

/// A volume other than the startup disk that Basil's filename index covers. `id` stays the same
/// across mounts: "uuid:<volume UUID>" for local disks, "url:<address>" for network volumes
/// (smb://user@host/share), "name:<name>" when a local disk has no UUID.
public struct IndexedVolume: Codable, Hashable, Sendable {
    public var id: String
    /// The name it had when last seen, shown while it is not mounted.
    public var name: String
    public var isNetwork: Bool

    public init(id: String, name: String, isNetwork: Bool) {
        self.id = id
        self.name = name
        self.isNetwork = isNetwork
    }
}

/// One plugin's state in Settings > Plugins.
public struct PluginSetting: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Permission names granted ("network", "shell", "ffi").
    public var granted: [String]

    public init(enabled: Bool, granted: [String] = []) {
        self.enabled = enabled
        self.granted = granted
    }
}
