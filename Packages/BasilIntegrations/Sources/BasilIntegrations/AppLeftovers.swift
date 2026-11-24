import Foundation
import Security

/// What identifies an app's files outside its bundle: its bundle ID, the IDs of the bundles inside
/// it (helpers, login items, XPC services, extensions, each of which can have its own container),
/// its app groups (Group Containers), and its names (some apps use their name for folders).
public struct AppIdentity: Sendable, Equatable {
    public var bundleURL: URL
    public var bundleID: String
    /// Bundle IDs of the bundles inside the app.
    public var helperIDs: [String]
    /// From the code signature's com.apple.security.application-groups.
    public var appGroups: [String]
    /// File name without .app, CFBundleName, CFBundleDisplayName and the executable name.
    public var names: [String]
    /// The executable names (crash reports are named after the process).
    public var executables: [String]

    public init(bundleURL: URL, bundleID: String, helperIDs: [String] = [], appGroups: [String] = [],
                names: [String] = [], executables: [String] = []) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.helperIDs = helperIDs
        self.appGroups = appGroups
        self.names = names
        self.executables = executables
    }

    /// Every bundle ID that leftovers can be named after.
    public var allIDs: [String] { [bundleID] + helperIDs }

    /// Reads the identity of an .app bundle, or nil when it has no bundle ID.
    public static func read(appAt url: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        var helperIDs: [String] = [], groups = Set(entitlementGroups(of: url)), executables: [String] = []
        if let exe = bundle.executableURL?.lastPathComponent { executables.append(exe) }
        for nested in nestedBundles(in: url) {
            // Only the app's own helpers: a bundled updater (Sparkle and the like) has a shared ID
            // whose files belong to every app that uses it.
            guard let b = Bundle(url: nested), let nestedID = b.bundleIdentifier, nestedID != id,
                  nestedID.lowercased().hasPrefix(id.lowercased()) else { continue }
            helperIDs.append(nestedID)
            // Crash reports are matched by process name, so only helpers named after the app count
            // ("Discord Helper (GPU)"); an extension's executable can be called "Safari".
            if let exe = b.executableURL?.lastPathComponent, let main = executables.first,
               exe.lowercased().contains(main.lowercased()) {
                executables.append(exe)
            }
            groups.formUnion(entitlementGroups(of: nested))
        }
        let info = bundle.infoDictionary ?? [:]
        var names = [url.deletingPathExtension().lastPathComponent]
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            if let n = info[key] as? String { names.append(n) }
        }
        names += executables.prefix(1)
        return AppIdentity(bundleURL: url, bundleID: id, helperIDs: unique(helperIDs), appGroups: groups.sorted(),
                           names: unique(names), executables: unique(executables))
    }

    /// Bundles inside the app that macOS registers on their own.
    private static func nestedBundles(in app: URL) -> [URL] {
        let contents = app.appendingPathComponent("Contents")
        let places = ["Library/LoginItems", "Library/LaunchServices", "Library/SystemExtensions", "XPCServices",
                      "PlugIns", "Extensions", "Helpers", "Frameworks", "Library/QuickLook", "Library/Spotlight"]
        var found: [URL] = []
        for place in places {
            let folder = contents.appendingPathComponent(place)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where !name.hasSuffix(".framework") && !name.hasSuffix(".dylib") {
                let url = folder.appendingPathComponent(name)
                if Bundle(url: url)?.bundleIdentifier != nil { found.append(url) }
            }
        }
        return found
    }

    static func entitlementGroups(of url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// One file or folder an app left behind.
public struct AppLeftover: Sendable, Equatable, Identifiable {
    public var url: URL
    /// What it is, in words ("Preferences", "Launch agent").
    public var kind: String
    /// Total size in bytes (folders counted).
    public var size: Int64
    /// It can only be removed with an administrator password.
    public var needsAdmin: Bool
    /// Found by the app's name rather than its bundle ID (less certain).
    public var matchedByName: Bool
    /// Another installed app that uses this group container too (it then starts unticked).
    public var sharedWith: String?

    public var id: URL { url }
}

/// Finds what an app leaves outside its bundle, like ForkLift's app delete: caches, logs,
/// preferences, containers, launch agents and daemons, helper tools, saved state, crash reports,
/// temporary folders under /var/folders, package receipts.
///
/// Matching is strict, because everything found starts ticked: a name must equal one of the app's
/// bundle IDs or start with one followed by a dot ("com.example.App.plist"); app names only count
/// in folders where apps use plain names (Application Support, Caches, Logs) and must match whole;
/// launchd plists count when their label matches or their program lies inside the app.
public struct AppLeftoverFinder: Sendable {
    /// Where to look. Tests pass temporary folders.
    public struct Roots: Sendable {
        public var home: URL
        public var systemLibrary: URL
        /// The per-user cache and temporary folders under /var/folders.
        public var userCache: URL?
        public var userTemp: URL?
        public var receipts: URL
        /// The volume package paths are relative to ("/"; tests use a folder).
        public var volume: URL

        public init(home: URL, systemLibrary: URL, userCache: URL?, userTemp: URL?, receipts: URL,
                    volume: URL = URL(fileURLWithPath: "/")) {
            self.home = home
            self.systemLibrary = systemLibrary
            self.userCache = userCache
            self.userTemp = userTemp
            self.receipts = receipts
            self.volume = volume
        }

        public static var system: Roots {
            Roots(home: FileManager.default.homeDirectoryForCurrentUser,
                  systemLibrary: URL(fileURLWithPath: "/Library"),
                  userCache: darwinFolder(_CS_DARWIN_USER_CACHE_DIR),
                  userTemp: darwinFolder(_CS_DARWIN_USER_TEMP_DIR),
                  receipts: URL(fileURLWithPath: "/private/var/db/receipts"))
        }

        private static func darwinFolder(_ name: Int32) -> URL? {
            let length = confstr(name, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            guard confstr(name, &buffer, length) > 0 else { return nil }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    enum Rule {
        /// Named after a bundle ID.
        case id
        /// Named after a bundle ID or the app's name.
        case idOrName
        /// Crash and hang reports: "<executable>-2026-11-22-...ips", "<executable>_<id>.plist".
        case report
        /// launchd plists: label or program.
        case launchd
        /// Group Containers: an app group or a bundle ID.
        case group
        /// Plug-in folders: a bundle whose own CFBundleIdentifier (or name) is one of the app's IDs.
        case bundle
    }

    struct Place {
        let folder: URL
        let kind: String
        let rule: Rule
    }

    public let roots: Roots

    public init(roots: Roots = .system) {
        self.roots = roots
    }

    var places: [Place] {
        let user = roots.home.appendingPathComponent("Library")
        let system = roots.systemLibrary
        func u(_ path: String, _ kind: String, _ rule: Rule) -> Place { Place(folder: user.appendingPathComponent(path), kind: kind, rule: rule) }
        func s(_ path: String, _ kind: String, _ rule: Rule) -> Place { Place(folder: system.appendingPathComponent(path), kind: kind, rule: rule) }
        var places = [
            u("Application Support", "Application support", .idOrName),
            u("Application Support/CrashReporter", "Crash reporter data", .report),
            u("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", "Recent documents list", .id),
            u("Application Scripts", "Application scripts", .id),
            u("Caches", "Cache", .idOrName),
            u("Containers", "Container", .id),
            u("Group Containers", "Group container", .group),
            u("Preferences", "Preferences", .id),
            u("Preferences/ByHost", "Preferences for this Mac", .id),
            u("Saved Application State", "Saved window state", .id),
            u("Logs", "Logs", .idOrName),
            u("Logs/DiagnosticReports", "Crash report", .report),
            u("HTTPStorages", "Web storage", .id),
            u("WebKit", "Web data", .id),
            u("Cookies", "Cookies", .id),
            u("LaunchAgents", "Launch agent", .launchd),
            u("Autosave Information", "Autosaved documents", .id),
            u("Application Support/FileProvider", "File provider data", .id),
            u("Caches/com.apple.nsurlsessiond/Downloads", "Background downloads", .id),
            u("Caches/com.crashlytics.data", "Crash reporter data", .id),
            u("Caches/com.plausiblelabs.crashreporter.data", "Crash reporter data", .id),
            u("Application Support/com.crashlytics", "Crash reporter data", .id),
            s("Application Support", "Application support (all users)", .idOrName),
            s("Caches", "Cache (all users)", .idOrName),
            s("Preferences", "Preferences (all users)", .id),
            s("LaunchAgents", "Launch agent (all users)", .launchd),
            s("LaunchDaemons", "Launch daemon", .launchd),
            s("PrivilegedHelperTools", "Privileged helper tool", .id),
            s("Logs", "Logs (all users)", .idOrName),
            s("Logs/DiagnosticReports", "Crash report (all users)", .report),
            s("StartupItems", "Startup item", .idOrName),
            s("Extensions", "Kernel extension", .bundle),
            s("Frameworks", "Framework (all users)", .bundle),
            s("Security/SecurityAgentPlugins", "Security agent plug-in", .bundle),
            s("DirectoryServices/PlugIns", "Directory services plug-in", .bundle),
            s("Audio/MIDI Drivers", "MIDI driver", .bundle),
            Place(folder: roots.receipts, kind: "Installer receipt", rule: .id),
        ]
        // Plug-ins an app installs for itself, in the user's and the system Library.
        for (path, kind) in Self.pluginFolders {
            places.append(u(path, kind, .bundle))
            places.append(s(path, kind + " (all users)", .bundle))
        }
        if let cache = roots.userCache { places.append(Place(folder: cache, kind: "Cache (var/folders)", rule: .id)) }
        if let temp = roots.userTemp { places.append(Place(folder: temp, kind: "Temporary files (var/folders)", rule: .id)) }
        return places
    }

    static let pluginFolders: [(String, String)] = [
        ("QuickLook", "Quick Look plug-in"),
        ("Spotlight", "Spotlight importer"),
        ("PreferencePanes", "Settings pane"),
        ("Internet Plug-Ins", "Internet plug-in"),
        ("Screen Savers", "Screen saver"),
        ("Audio/Plug-Ins/Components", "Audio Unit"),
        ("Audio/Plug-Ins/VST", "VST plug-in"),
        ("Audio/Plug-Ins/VST3", "VST3 plug-in"),
        ("Audio/Plug-Ins/HAL", "Audio driver"),
        ("Input Methods", "Input method"),
        ("ColorPickers", "Colour picker"),
        ("Services", "Service"),
        ("Contextual Menu Items", "Contextual menu item"),
        ("Mail/Bundles", "Mail plug-in"),
    ]

    /// The bundle identifier of a bundle (Contents/Info.plist or Info.plist), lowercased.
    static func bundleID(of url: URL) -> String? {
        for info in ["Contents/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(info)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return (plist["CFBundleIdentifier"] as? String)?.lowercased()
        }
        return nil
    }

    /// Searches every place. Blocking (file system walks); call it off the main thread.
    public func find(for app: AppIdentity) -> [AppLeftover] {
        let fm = FileManager.default
        let ids = app.allIDs.map { $0.lowercased() }.filter { $0.count >= 3 }
        let groups = app.appGroups.map { $0.lowercased() }
        let names = app.names.map { $0.lowercased() }.filter { $0.count >= 3 }
        let reportPrefixes = app.executables.map { $0.lowercased() }.filter { $0.count >= 3 }
        let bundlePath = app.bundleURL.standardizedFileURL.path
        guard !ids.isEmpty || !names.isEmpty else { return [] }

        func matchesID(_ name: String) -> Bool {
            ids.contains { name == $0 || name.hasPrefix($0 + ".") }
        }

        var found: [AppLeftover] = []
        var seen = Set<String>()
        var groupUsers: [String: [String]]?
        for place in places {
            guard let entries = try? fm.contentsOfDirectory(atPath: place.folder.path) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                var byName = false
                var sharedWith: String?
                let match: Bool
                switch place.rule {
                case .id:
                    match = matchesID(lower)
                case .idOrName:
                    if matchesID(lower) { match = true } else {
                        match = names.contains(lower)
                        byName = match
                    }
                case .group:
                    if matchesID(lower) { match = true } else if groups.contains(lower) {
                        match = true
                        if groupUsers == nil { groupUsers = Self.installedGroupUsers(excluding: bundlePath, home: roots.home) }
                        sharedWith = groupUsers?[lower]?.first
                    } else {
                        match = false
                    }
                case .report:
                    match = reportPrefixes.contains { p in
                        lower.hasPrefix(p + "-") || lower.hasPrefix(p + "_") || lower.hasPrefix(p + ".")
                    }
                case .bundle:
                    let url = place.folder.appendingPathComponent(entry)
                    match = Self.bundleID(of: url).map(matchesID) ?? matchesID(lower)
                case .launchd:
                    let url = place.folder.appendingPathComponent(entry)
                    match = lower.hasSuffix(".plist") && (matchesID(lower) || Self.launchdPlist(url, belongsTo: bundlePath, ids: ids))
                }
                guard match else { continue }
                let url = place.folder.appendingPathComponent(entry)
                let path = url.standardizedFileURL.path
                // Never anything inside the app itself, and each item once.
                guard !path.hasPrefix(bundlePath + "/"), path != bundlePath, seen.insert(path).inserted else { continue }
                found.append(AppLeftover(url: url, kind: place.kind, size: Self.size(of: url),
                                         needsAdmin: !fm.isDeletableFile(atPath: url.path), matchedByName: byName,
                                         sharedWith: sharedWith))
            }
        }
        for leftover in packageLeftovers(for: app, ids: ids, names: names) {
            let path = leftover.url.standardizedFileURL.path
            if seen.insert(path).inserted { found.append(leftover) }
        }
        return found
    }

    // MARK: Packages

    /// What an installer package left: the receipts of packages whose file list (BOM) contains
    /// the app, and what those packages installed outside any app bundle that is still there.
    /// Bundles (plug-ins, kexts, frameworks) and folders named after the app come whole when every
    /// item in them is the package's; other files one by one, so folders shared with other
    /// software (/usr/local/bin, /Library/Audio/Plug-Ins) are never offered. A package that also
    /// installed another app that is still there marks its items as shared (they start unticked).
    func packageLeftovers(for app: AppIdentity, ids: [String], names: [String]) -> [AppLeftover] {
        let fm = FileManager.default
        let volume = roots.volume.standardizedFileURL.path
        let bundlePath = app.bundleURL.standardizedFileURL.path
        let appName = Data(app.bundleURL.lastPathComponent.utf8)
        guard let entries = try? fm.contentsOfDirectory(atPath: roots.receipts.path) else { return [] }
        var found: [AppLeftover] = []
        for entry in entries.sorted() where entry.hasSuffix(".plist") && !entry.hasPrefix("com.apple.") {
            let plistURL = roots.receipts.appendingPathComponent(entry)
            let bomURL = plistURL.deletingPathExtension().appendingPathExtension("bom")
            // Cheap check first: the BOM stores each path part as a string.
            guard let bom = try? Data(contentsOf: bomURL), bom.range(of: appName) != nil,
                  let data = try? Data(contentsOf: plistURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let packageID = info["PackageIdentifier"] as? String ?? plistURL.deletingPathExtension().lastPathComponent
            let prefix = (info["InstallPrefixPath"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = prefix.isEmpty ? volume : (volume as NSString).appendingPathComponent(prefix)
            let paths = Self.bomPaths(bomURL).map { rel -> String in
                let r = rel.hasPrefix("./") ? String(rel.dropFirst(2)) : (rel == "." ? "" : rel)
                return r.isEmpty ? base : (base as NSString).appendingPathComponent(r)
            }
            guard paths.contains(bundlePath) else { continue }
            let owned = Set(paths)
            // Another app this package installed that is still there.
            let otherApp = paths.first { p in
                p.hasSuffix(".app") && p != bundlePath && !Self.insideApp(String(p.dropLast(4))) && fm.fileExists(atPath: p)
            }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            let kind = "Installed by package \(packageID)"
            func add(_ path: String, kind: String) {
                let url = URL(fileURLWithPath: path)
                found.append(AppLeftover(url: url, kind: kind, size: Self.size(of: url),
                                         needsAdmin: !fm.isDeletableFile(atPath: path), matchedByName: false,
                                         sharedWith: otherApp))
            }
            for receipt in [plistURL, bomURL] where fm.fileExists(atPath: receipt.path) {
                add(receipt.path, kind: "Installer receipt")
            }
            var offered: [String] = []
            for path in paths.sorted() {
                guard path != base, path.hasPrefix(volume == "/" ? "/" : volume + "/"),
                      !Self.insideApp(path), !offered.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
                let relative = volume == "/" ? path : String(path.dropFirst(volume.count))
                guard !Self.protectedPrefixes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
                        || relative.hasPrefix("/usr/local/") || relative.hasPrefix("/opt/") else { continue }
                var isDir: ObjCBool = false
                guard (try? fm.attributesOfItem(atPath: path)) != nil else { continue } // gone (lstat)
                _ = fm.fileExists(atPath: path, isDirectory: &isDir)
                let isLink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
                if isDir.boolValue, !isLink {
                    let name = (path as NSString).lastPathComponent.lowercased()
                    let isBundle = !(name as NSString).pathExtension.isEmpty
                    let named = names.contains(name) || ids.contains { name == $0 || name.hasPrefix($0 + ".") }
                    if (isBundle || named), Self.onlyContains(path, owned) {
                        offered.append(path)
                        add(path, kind: kind)
                    }
                    continue
                }
                offered.append(path)
                add(path, kind: kind)
            }
        }
        return found
    }

    /// Top-level system places a package's own files are never offered from (except
    /// /usr/local and /opt, where tools install).
    static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/dev", "/Volumes", "/Users"]

    /// Whether a path lies inside an app bundle (any part ending in .app before the last one).
    static func insideApp(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.dropLast().contains { $0.lowercased().hasSuffix(".app") } || path.lowercased().hasSuffix(".app")
    }

    /// Whether everything below a folder is in the package's file list.
    static func onlyContains(_ folder: String, _ owned: Set<String>) -> Bool {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return false }
        for case let rel as String in walker where !owned.contains((folder as NSString).appendingPathComponent(rel)) {
            return false
        }
        return true
    }

    /// The paths in a BOM file ("./Applications/Foo.app", ...), through lsbom.
    static func bomPaths(_ bom: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsbom")
        process.arguments = ["-s", bom.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// App groups of the other installed apps (lowercased group -> app names), read from their
    /// code signatures. Only needed when a group container was found.
    static func installedGroupUsers(excluding bundlePath: String, home: URL) -> [String: [String]] {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       home.appendingPathComponent("Applications").path]
        var users: [String: [String]] = [:]
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard url.standardizedFileURL.path != bundlePath else { continue }
                for group in AppIdentity.entitlementGroups(of: url) {
                    users[group.lowercased(), default: []].append(url.deletingPathExtension().lastPathComponent)
                }
            }
        }
        return users
    }

    /// A launchd job belongs to the app when its label is one of the app's IDs or its program is
    /// inside the app bundle.
    static func launchdPlist(_ url: URL, belongsTo bundlePath: String, ids: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        if let label = (plist["Label"] as? String)?.lowercased(), ids.contains(where: { label == $0 || label.hasPrefix($0 + ".") }) {
            return true
        }
        var programs: [String] = []
        if let p = plist["Program"] as? String { programs.append(p) }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first { programs.append(first) }
        return programs.contains { $0.hasPrefix(bundlePath + "/") }
    }

    /// Allocated size of a file or folder tree; symlinks are not followed.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        func one(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total = one(url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                          errorHandler: { _, _ in true })
        else { return total }
        for case let child as URL in walker { total += one(child) }
        return total
    }

    /// Other copies of the app that are still installed (outside the Trash). Their leftovers are
    /// shared, so nothing is offered while one exists.
    public static func otherInstalledCopies(of app: AppIdentity, excluding removed: URL) -> [URL] {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let removedPath = removed.standardizedFileURL.path
        return LSApps.urls(forBundleID: app.bundleID).filter { url in
            let path = url.standardizedFileURL.path
            return path != removedPath && !path.hasPrefix(trash + "/") && !path.contains("/.Trashes/")
                && FileManager.default.fileExists(atPath: path)
        }
    }
}

/// Launch Services lookups, kept apart so the finder itself has no AppKit dependency.
enum LSApps {
    static func urls(forBundleID id: String) -> [URL] {
        guard let unmanaged = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil) else { return [] }
        return (unmanaged.takeRetainedValue() as? [URL]) ?? []
    }
}

public enum AppCleanup {
    /// The leftovers of an app that was just removed, or nil when it was not removed after all
    /// (failed or skipped) or another copy of it is still installed. Blocking.
    public static func leftoversOfRemovedApp(_ app: AppIdentity, finder: AppLeftoverFinder) -> [AppLeftover]? {
        if FileManager.default.fileExists(atPath: app.bundleURL.path) { return nil }
        if !AppLeftoverFinder.otherInstalledCopies(of: app, excluding: app.bundleURL).isEmpty { return nil }
        return finder.find(for: app)
    }
}
