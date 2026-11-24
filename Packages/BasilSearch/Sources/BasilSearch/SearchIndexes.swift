import BasilCore
import CryptoKit
import Foundation
import Synchronization

/// A mounted volume that can be indexed (not the startup disk).
public struct MountedVolume: Sendable, Hashable {
    /// The identity kept in settings (`IndexedVolume.id`).
    public var id: String
    public var name: String
    /// Where it is mounted now ("/Volumes/KINGSTON").
    public var path: String
    public var isNetwork: Bool

    public init(id: String, name: String, path: String, isNetwork: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isNetwork = isNetwork
    }

    /// The volumes mounted now, without the startup disk and the system's hidden ones.
    public static func current() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeURLForRemountingKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [MountedVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsRootFileSystem == true || url.path == "/" { continue }
            if values.volumeIsBrowsable == false { continue }
            let name = values.volumeName ?? url.lastPathComponent
            let isNetwork = values.volumeIsLocal == false
            result.append(MountedVolume(id: identity(isNetwork: isNetwork, uuid: values.volumeUUIDString,
                                                     remountURL: values.volumeURLForRemounting, name: name),
                                        name: name, path: url.path, isNetwork: isNetwork))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "uuid:..." for local disks, "url:smb://user@host/share" (never with a password) for
    /// network volumes, "name:..." when nothing better is known.
    static func identity(isNetwork: Bool, uuid: String?, remountURL: URL?, name: String) -> String {
        if !isNetwork, let uuid, !uuid.isEmpty { return "uuid:" + uuid.uppercased() }
        if isNetwork, let remountURL, var parts = URLComponents(url: remountURL, resolvingAgainstBaseURL: false) {
            parts.password = nil
            if let text = parts.string { return "url:" + text }
        }
        return "name:" + name
    }
}

/// Every filename index Basil keeps: the startup disk's and one per volume ticked in Settings.
/// A volume's index runs only while the volume is mounted; its file stays when it is unmounted,
/// and changes made meanwhile are replayed from the volume's FSEvents history when it comes back
/// (network volumes are scanned again instead, and every few hours).
@MainActor
public final class SearchIndexes {
    /// The startup disk's index (or the fixture's in UI tests).
    public let boot: FilenameIndex?
    /// The indexes running now, read by `IndexSearchEngine` from any thread.
    public nonisolated let active: ActiveIndexes
    public let folder: URL
    private var bootRunning = false
    private var chosen: [IndexedVolume] = []
    private var rescanHours = 6
    /// Running volume indexes by volume identity.
    private(set) var volumes: [String: FilenameIndex] = [:]
    /// Called after the set of running indexes changed (Settings shows each one's state).
    public var onChange: (() -> Void)?
    /// Lists the mounted volumes (replaced in tests).
    var mounted: () -> [MountedVolume] = MountedVolume.current

    public init(folder: URL, boot: FilenameIndex?) {
        self.folder = folder
        self.boot = boot
        active = ActiveIndexes()
    }

    /// The index file of a volume.
    nonisolated static func file(for id: String, in folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("Volume \(digest).basilindex")
    }

    /// The running index of a volume, if any.
    public func index(forVolume id: String) -> FilenameIndex? { volumes[id] }

    /// Matches Settings: the startup disk on or off, the ticked volumes, the network rescan time.
    /// A volume no longer ticked has its file deleted.
    public func apply(bootOn: Bool, chosen: [IndexedVolume], rescanHours: Int) {
        if let boot, bootOn != bootRunning {
            bootRunning = bootOn
            Task { if bootOn { await boot.start() } else { await boot.stop(deleting: true) } }
        }
        let removed = Set(self.chosen.map(\.id)).subtracting(chosen.map(\.id))
        let hoursChanged = rescanHours != self.rescanHours
        self.chosen = chosen
        self.rescanHours = max(1, rescanHours)
        for id in removed {
            if let index = volumes.removeValue(forKey: id) {
                Task { await index.stop(deleting: true) }
            } else {
                try? FileManager.default.removeItem(at: Self.file(for: id, in: folder))
            }
        }
        if hoursChanged {
            for index in volumes.values where index.isNetwork {
                let interval = Duration.seconds(self.rescanHours * 3600)
                Task { await index.setRescanInterval(interval) }
            }
        }
        volumesChanged()
    }

    /// Starts the indexes of ticked volumes that are mounted now and stops those that are gone
    /// (after a volume was mounted, unmounted or renamed).
    public func volumesChanged() {
        let mountedNow = mounted()
        let wanted = Set(chosen.map(\.id))
        var seen: Set<String> = []
        for volume in mountedNow where wanted.contains(volume.id) {
            seen.insert(volume.id)
            if let running = volumes[volume.id] {
                if running.root == volume.path { continue }
                // Mounted at another path now: start over there.
                volumes[volume.id] = nil
                Task { await running.stop() }
            }
            let index = FilenameIndex.volume(at: volume.path, file: Self.file(for: volume.id, in: folder), isNetwork: volume.isNetwork)
            volumes[volume.id] = index
            let interval = volume.isNetwork ? Duration.seconds(rescanHours * 3600) : nil
            Task {
                await index.setRescanInterval(interval)
                await index.start()
            }
        }
        for (id, index) in volumes where !seen.contains(id) {
            volumes[id] = nil
            Task { await index.stop() }
        }
        publish()
    }

    /// Stops the index of the volume mounted at `path` before it is unmounted, so it never holds
    /// the volume busy.
    public func volumeWillUnmount(at path: String) {
        for (id, index) in volumes where index.root == path {
            volumes[id] = nil
            Task { await index.stop() }
        }
        publish()
    }

    private func publish() {
        var list: [FilenameIndex] = []
        if let boot, bootRunning { list.append(boot) }
        list += volumes.values
        active.set(list)
        onChange?()
    }

    /// Writes unsaved changes of every running index (at quit).
    public func saveAll() async {
        for index in active.all { await index.saveIfNeeded() }
    }
}

/// The running indexes, readable from any thread.
public final class ActiveIndexes: Sendable {
    private let list = Mutex<[FilenameIndex]>([])

    public init(_ indexes: [FilenameIndex] = []) {
        list.withLock { $0 = indexes }
    }

    public var all: [FilenameIndex] { list.withLock { $0 } }

    func set(_ indexes: [FilenameIndex]) { list.withLock { $0 = indexes } }

    /// The most specific index covering `path`.
    public func covering(_ path: String) -> FilenameIndex? {
        all.filter { $0.covers(path) }.max { $0.root.count < $1.root.count }
    }
}
