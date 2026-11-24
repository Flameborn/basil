import AppKit
import BasilCore
import BasilSearch
import Foundation

/// The indexes for Settings: one row per volume that can be indexed (the startup disk, the
/// mounted volumes, and ticked volumes that are not mounted now), each with its state in words.
@MainActor
@Observable
final class SearchIndexStatus {
    struct Row: Identifiable, Equatable {
        /// "boot" for the startup disk, else the volume identity.
        var id: String
        var name: String
        var isNetwork: Bool
        var isMounted: Bool
        var status: String
    }

    private(set) var rows: [Row] = []
    @ObservationIgnored let indexes: SearchIndexes
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observed: Set<ObjectIdentifier> = []
    @ObservationIgnored private var states: [ObjectIdentifier: FilenameIndex.State] = [:]

    init(indexes: SearchIndexes, settings: SettingsStore) {
        self.indexes = indexes
        self.settings = settings
        refresh()
    }

    /// Lists the volumes again and each index's state (after mounts and setting changes).
    func refresh() {
        var result: [Row] = []
        if let boot = indexes.boot {
            result.append(Row(id: "boot", name: Self.bootName, isNetwork: false, isMounted: true,
                              status: settings.settings.searchIndex ? text(for: boot) : "Status: off"))
        }
        let chosen = settings.settings.indexedVolumes
        let mounted = MountedVolume.current()
        for volume in mounted {
            let ticked = chosen.contains { $0.id == volume.id }
            result.append(Row(id: volume.id, name: volume.name, isNetwork: volume.isNetwork, isMounted: true,
                              status: ticked ? indexes.index(forVolume: volume.id).map(text(for:)) ?? "Status: starting" : "Status: off"))
        }
        for volume in chosen where !mounted.contains(where: { $0.id == volume.id }) {
            result.append(Row(id: volume.id, name: volume.name, isNetwork: volume.isNetwork, isMounted: false,
                              status: "Status: not mounted, kept for when it is back"))
        }
        if result != rows { rows = result }
    }

    /// The startup disk's name ("Macintosh HD").
    static var bootName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Startup disk"
    }

    func isOn(_ row: Row) -> Bool {
        row.id == "boot" ? settings.settings.searchIndex : settings.settings.indexedVolumes.contains { $0.id == row.id }
    }

    func set(_ row: Row, on: Bool) {
        if row.id == "boot" {
            settings.settings.searchIndex = on
            return
        }
        var chosen = settings.settings.indexedVolumes.filter { $0.id != row.id }
        if on { chosen.append(IndexedVolume(id: row.id, name: row.name, isNetwork: row.isNetwork)) }
        settings.settings.indexedVolumes = chosen
    }

    func rebuild(_ row: Row) {
        guard let index = row.id == "boot" ? indexes.boot : indexes.index(forVolume: row.id) else { return }
        Task { await index.rebuild() }
    }

    private func text(for index: FilenameIndex) -> String {
        let id = ObjectIdentifier(index)
        if !observed.contains(id) {
            observed.insert(id)
            index.observe { [weak self] state in
                Task { @MainActor in
                    self?.states[id] = state
                    self?.refresh()
                }
            }
        }
        return Self.describe(states[id] ?? index.state)
    }

    static func describe(_ state: FilenameIndex.State) -> String {
        switch state {
        case .off: "Status: off"
        case .loading: "Status: loading"
        case .scanning(let count): "Status: building, \(count.formatted()) items so far"
        case .ready(let count): "Status: up to date, \(count.formatted()) items"
        case .refreshing(let count, let scanned): "Status: \(count.formatted()) items, scanning again (\(scanned.formatted()) so far)"
        case .failed(let reason): "Status: could not be built: \(reason)"
        }
    }
}

extension MainWindowController {
    /// At quit: writes the indexes' unsaved changes (waits up to two seconds). Changes not saved
    /// are replayed from FSEvents at the next start anyway.
    public func saveSearchIndex() {
        guard let indexes = searchIndexes else { return }
        let done = DispatchSemaphore(value: 0)
        let active = indexes.active
        Task.detached {
            for index in active.all { await index.saveIfNeeded() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Starts or stops the indexes to match Settings (a volume unticked has its file deleted).
    func applySearchIndexSetting() {
        guard let indexes = searchIndexes else { return }
        let current = settings.settings
        indexes.apply(bootOn: current.searchIndex, chosen: current.indexedVolumes, rescanHours: current.networkIndexRescanHours)
        searchIndexStatus?.refresh()
    }

    /// Follows volumes being mounted and unmounted. An index lets go of its volume before it is
    /// unmounted, so it never keeps a disk from being ejected.
    func observeVolumesForSearchIndex() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                ?? note.userInfo?["NSDevicePath"] as? String
            MainActor.assumeIsolated {
                if let path { self?.searchIndexes?.volumeWillUnmount(at: path) }
                self?.searchIndexStatus?.refresh()
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.searchIndexes?.volumesChanged()
                    self?.searchIndexStatus?.refresh()
                }
            }
        }
    }
}
