import BasilCore
import BasilVFS
import Foundation
import Observation

/// The plugins in Basil's Plugins folder (Application Support/Basil/Plugins, one folder per
/// plugin with a plugin.json): which are on, what they may do, their logs. New plugins are off
/// until turned on in Settings > Plugins, which is when their permissions are asked.
@MainActor
@Observable
public final class PluginManager {
    public struct Entry: Identifiable, Equatable {
        /// The manifest's id, or the folder's name when plugin.json could not be read.
        public var id: String
        public var folder: URL
        public var manifest: PluginManifest?
        /// Why it is not running (plugin.json, main.lua or a Lua error), if it is not.
        public var problem: String?
        public var isEnabled: Bool
        public var isLoaded: Bool
        public var granted: Set<PluginPermission>
        /// The plugin's print output and errors, newest last.
        public var log: [String]

        public var name: String { manifest?.name ?? folder.lastPathComponent }
    }

    public private(set) var entries: [Entry] = []
    public let folder: URL
    @ObservationIgnored let registry: ProviderRegistry
    @ObservationIgnored let commands: CommandRegistry
    @ObservationIgnored public weak var host: (any PluginHost)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var loaded: [String: Plugin] = [:]

    public init(folder: URL, registry: ProviderRegistry, commands: CommandRegistry, settings: SettingsStore) {
        self.folder = folder
        self.registry = registry
        self.commands = commands
        self.settings = settings
    }

    /// The default folder: ~/Library/Application Support/Basil/Plugins.
    public static func defaultFolder(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    /// Reads the Plugins folder again (plugin.json of every folder in it).
    public func scan() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var result: [Entry] = []
        var seen: Set<String> = []
        for plugin in folders {
            let saved = { (id: String) in self.settings.settings.plugins[id] }
            do {
                let manifest = try PluginManifest.read(in: plugin)
                guard seen.insert(manifest.id).inserted else {
                    result.append(Entry(id: plugin.lastPathComponent, folder: plugin, manifest: manifest,
                                        problem: "Another plugin already has the id \(manifest.id)", isEnabled: false,
                                        isLoaded: false, granted: [], log: []))
                    continue
                }
                let setting = saved(manifest.id)
                let old = entries.first { $0.id == manifest.id }
                result.append(Entry(id: manifest.id, folder: plugin, manifest: manifest, problem: old?.problem,
                                    isEnabled: setting?.enabled ?? false, isLoaded: loaded[manifest.id] != nil,
                                    granted: Set((setting?.granted ?? []).compactMap(PluginPermission.init(rawValue:))),
                                    log: old?.log ?? []))
            } catch {
                result.append(Entry(id: plugin.lastPathComponent, folder: plugin, manifest: nil,
                                    problem: (error as? PluginError)?.message ?? error.localizedDescription,
                                    isEnabled: false, isLoaded: false, granted: [], log: []))
            }
        }
        // Plugins whose folder went away are stopped.
        for (id, plugin) in loaded where !result.contains(where: { $0.id == id && $0.manifest != nil }) {
            plugin.stop()
            loaded[id] = nil
        }
        entries = result
    }

    /// Starts every plugin that is turned on (at launch).
    public func startEnabled() async {
        scan()
        for entry in entries where entry.isEnabled && entry.manifest != nil && !entry.isLoaded {
            await load(entry.id)
        }
    }

    /// Turns a plugin on (asking for the permissions it wants that are not granted yet) or off.
    public func setEnabled(_ id: String, _ on: Bool) async {
        guard let entry = entries.first(where: { $0.id == id }), let manifest = entry.manifest else { return }
        if on {
            let missing = manifest.wanted.subtracting(entry.granted)
            var granted = entry.granted
            if !missing.isEmpty {
                guard let host, await host.ask(.permissions(plugin: manifest.name, permissions: missing.sorted())) == .confirmed else {
                    return
                }
                granted.formUnion(missing)
            }
            save(id, PluginSetting(enabled: true, granted: granted.map(\.rawValue).sorted()))
            await load(id)
        } else {
            save(id, PluginSetting(enabled: false, granted: entry.granted.map(\.rawValue).sorted()))
            unload(id)
            update(id) { $0.problem = nil }
        }
    }

    /// Stops a plugin and starts it again with its current files.
    public func reload(_ id: String) async {
        unload(id)
        scan()
        guard entries.first(where: { $0.id == id })?.isEnabled == true else { return }
        await load(id)
    }

    /// Stops every plugin (at quit).
    public func stopAll() {
        for id in loaded.keys { unload(id) }
    }

    private func save(_ id: String, _ setting: PluginSetting) {
        settings.settings.plugins[id] = setting
        update(id) { entry in
            entry.isEnabled = setting.enabled
            entry.granted = Set(setting.granted.compactMap(PluginPermission.init(rawValue:)))
        }
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    func append(_ line: String, to id: String) {
        update(id) { entry in
            entry.log.append(line)
            if entry.log.count > 200 { entry.log.removeFirst(entry.log.count - 200) }
        }
    }

    private func load(_ id: String) async {
        guard loaded[id] == nil, let entry = entries.first(where: { $0.id == id }), let manifest = entry.manifest else { return }
        // Permissions it wants and was not granted (added to plugin.json later) are not given.
        let granted = entry.granted.intersection(manifest.wanted)
        do {
            let plugin = try Plugin(manifest: manifest, folder: entry.folder, granted: granted, registry: registry,
                                    commands: commands, host: host) { [weak self] line in
                Task { @MainActor in self?.append(line, to: id) }
            }
            loaded[id] = plugin
            update(id) { $0.problem = nil; $0.isLoaded = true }
            do {
                try await plugin.start()
            } catch {
                let message = (error as? PluginError)?.message ?? error.localizedDescription
                append("Error starting: \(message)", to: id)
                unload(id)
                update(id) { $0.problem = message }
            }
        } catch {
            update(id) { $0.problem = (error as? PluginError)?.message ?? error.localizedDescription }
        }
    }

    private func unload(_ id: String) {
        loaded.removeValue(forKey: id)?.stop()
        update(id) { $0.isLoaded = false }
    }

    /// The loaded plugin with this id (tests).
    func plugin(_ id: String) -> Plugin? { loaded[id] }
}
