import BasilCore
import BasilVFS
import Foundation
import Synchronization
import Testing
@testable import BasilSearch

/// A small APFS disk image. Attached with -nobrowse it has no FSEvents history; attached
/// normally (shown on the desktop while the test runs) it has one.
private final class DiskImage {
    let folder: String
    let image: String
    private(set) var mountPoint: String?

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        folder = String(cString: realpath(url.path, &buffer))
        image = folder + "/disk.dmg"
        try Self.run(["create", "-quiet", "-size", "20m", "-fs", "APFS", "-volname", "BasilIndexTest", image])
    }

    func attach(as name: String, browsable: Bool = false) throws -> String {
        let point = folder + "/" + name
        try FileManager.default.createDirectory(atPath: point, withIntermediateDirectories: true)
        try Self.run(["attach", "-quiet"] + (browsable ? [] : ["-nobrowse"]) + ["-mountpoint", point, image])
        mountPoint = point
        return point
    }

    func detach(force: Bool = true) throws {
        guard let mountPoint else { return }
        try Self.run(["detach", "-quiet"] + (force ? ["-force"] : []) + [mountPoint])
        self.mountPoint = nil
    }

    func remove() {
        try? detach()
        try? FileManager.default.removeItem(atPath: folder)
    }

    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func waitReady(_ index: FilenameIndex) async throws {
    for _ in 0..<400 where !(index.state.isReady && !isRefreshing(index.state)) { try await Task.sleep(for: .milliseconds(25)) }
    #expect(index.state.isReady)
}

private func isRefreshing(_ state: FilenameIndex.State) -> Bool {
    if case .refreshing = state { true } else { false }
}

private func names(_ index: FilenameIndex, _ name: String, in folder: String) async throws -> [String] {
    try await index.search(SearchQuery(name: name), in: folder).map(\.name).sorted()
}

private func realTemporaryFolder() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-indexes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return String(cString: realpath(url.path, &buffer))
}

@Suite(.serialized) struct VolumeIndexTests {
    @Test(arguments: [true, false])
    func volumeIndexFollowsItsDiskToAnotherMountPointAndCatchesUp(withHistory: Bool) async throws {
        let disk = try DiskImage()
        defer { disk.remove() }
        let first = try disk.attach(as: "first", browsable: withHistory)
        // fseventsd sets up a browsable volume's history within a moment.
        for _ in 0..<50 where withHistory && FilenameIndex.volumeUUID(of: first).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(FilenameIndex.volumeUUID(of: first).isEmpty == !withHistory)
        let uuid = FilenameIndex.volumeUUID(of: first)
        try Data("x".utf8).write(to: URL(fileURLWithPath: first + "/song.mp3"))
        try FileManager.default.createDirectory(atPath: first + "/Albums", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: first + "/Albums/live.mp3"))
        let file = URL(fileURLWithPath: disk.folder + "/volume.basilindex")

        let index = FilenameIndex.volume(at: first, file: file, isNetwork: false)
        await index.start()
        try await waitReady(index)
        #expect(try await names(index, "*.mp3", in: first) == ["live.mp3", "song.mp3"])
        // The volume's own stores are recorded but not entered.
        #expect(try await names(index, "fseventsd-uuid", in: first).isEmpty)
        await index.stop()

        // Changed while Basil was not running, then mounted somewhere else.
        try Data("x".utf8).write(to: URL(fileURLWithPath: first + "/Albums/added.mp3"))
        try FileManager.default.removeItem(atPath: first + "/song.mp3")
        try await Task.sleep(for: .seconds(2))
        try disk.detach()
        #expect(!index.isMountedHere())
        let second = try disk.attach(as: "second", browsable: withHistory)
        for _ in 0..<50 where withHistory && FilenameIndex.volumeUUID(of: second).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(FilenameIndex.volumeUUID(of: second) == uuid)
        let again = FilenameIndex.volume(at: second, file: file, isNetwork: false)
        let states = Mutex<[FilenameIndex.State]>([])
        again.observe { state in states.withLock { $0.append(state) } }
        await again.start()
        try await waitReady(again)
        var found: [String] = []
        for _ in 0..<100 {
            found = try await names(again, "*.mp3", in: second)
            if found == ["added.mp3", "live.mp3"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(found == ["added.mp3", "live.mp3"])
        // With a history the changes are replayed (no scan); without one the disk is scanned again.
        let scanned = states.withLock { $0.contains { if case .scanning = $0 { true } else { isRefreshing($0) } } }
        #expect(scanned == !withHistory)
        let paths = try await again.search(SearchQuery(name: "added"), in: second).map(\.path.path)
        #expect(paths == [second + "/Albums/added.mp3"])
        await again.stop()
    }

    @Test func aScanOfAVolumeThatWentAwayKeepsTheIndex() async throws {
        let disk = try DiskImage()
        defer { disk.remove() }
        let point = try disk.attach(as: "mounted")
        try Data("x".utf8).write(to: URL(fileURLWithPath: point + "/kept.txt"))
        let index = FilenameIndex.volume(at: point, file: URL(fileURLWithPath: disk.folder + "/v.basilindex"), isNetwork: false)
        await index.start()
        try await waitReady(index)
        await index.stop()
        try disk.detach()
        // Nothing is scanned while the volume is not there (the mount point is an empty folder now).
        await index.rebuild()
        #expect(index.state == .off)
    }

    @Test func aRunningIndexDoesNotKeepTheVolumeFromBeingEjected() async throws {
        let disk = try DiskImage()
        defer { disk.remove() }
        let point = try disk.attach(as: "busy", browsable: true)
        let index = FilenameIndex.volume(at: point, file: URL(fileURLWithPath: disk.folder + "/v.basilindex"), isNetwork: false)
        await index.start()
        try await waitReady(index)
        try disk.detach(force: false)
        await index.stop()
    }

    @Test func networkVolumesAreScannedAgainWhileTheOldIndexStaysSearchable() async throws {
        let root = try realTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/old.txt"))
        let file = URL(fileURLWithPath: root + ".basilindex")
        defer { try? FileManager.default.removeItem(at: file) }
        let plain = FilenameIndex(file: file, root: root, scanner: IndexScanner(skippedPaths: [], devices: nil))
        await plain.start()
        try await waitReady(plain)
        await plain.stop()
        let scannedBefore = try IndexStore.read(from: file).scannedAt
        #expect(scannedBefore > 0)

        try await Task.sleep(for: .seconds(1.1))
        let network = FilenameIndex(file: file, root: root, scanner: IndexScanner(skippedPaths: [], devices: nil),
                                    isVolume: false, isNetwork: true)
        let states = Mutex<[FilenameIndex.State]>([])
        network.observe { state in states.withLock { $0.append(state) } }
        await network.start()
        // Ready at once from the file, then scanned again in the background.
        #expect(states.withLock { $0.contains { if case .ready = $0 { true } else { false } } })
        #expect(states.withLock { $0.contains { isRefreshing($0) } })
        #expect(try await names(network, "old", in: root) == ["old.txt"])
        try await waitReady(network)
        await network.stop()
        #expect(try IndexStore.read(from: file).scannedAt > scannedBefore)
    }

    @Test func searchesTakeInVolumesMountedBelowTheFolder() async throws {
        let root = try realTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Volumes/Disk", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/top.mp3"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/Volumes/Disk/deep.mp3"))
        // Like the startup disk: /Volumes is not entered; the disk has its own index.
        let outer = FilenameIndex(file: URL(fileURLWithPath: root + "/outer.basilindex"), root: root,
                                  scanner: IndexScanner(skippedPaths: [root + "/Volumes"], devices: nil))
        let disk = FilenameIndex(file: URL(fileURLWithPath: root + "/disk.basilindex"), root: root + "/Volumes/Disk",
                                 scanner: IndexScanner(skippedPaths: [], devices: nil))
        for index in [outer, disk] {
            await index.start()
            try await waitReady(index)
        }
        let engine = IndexSearchEngine(indexes: ActiveIndexes([outer, disk]))
        func found(in folder: String, subfolders: Bool = true) async throws -> [String] {
            var names: [String] = []
            for try await event in engine.search(SearchQuery(name: "*.mp3", subfolders: subfolders), in: .local(folder),
                                                 registry: ProviderRegistry()) {
                if case .found(let items) = event { names += items.map(\.name) }
            }
            return names.sorted()
        }
        #expect(try await found(in: root) == ["deep.mp3", "top.mp3"])
        #expect(try await found(in: root, subfolders: false) == ["top.mp3"])
        #expect(try await found(in: root + "/Volumes/Disk") == ["deep.mp3"])
        #expect(engine.refusal(for: SearchQuery(name: "x"), in: .local(root + "/Volumes"), registry: ProviderRegistry()) != nil)
        for index in [outer, disk] { await index.stop() }
    }

    @MainActor
    @Test func indexesFollowSettingsAndMounts() async throws {
        let root = try realTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/A", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/B", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/Index", withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: root + "/Index")
        let indexes = SearchIndexes(folder: folder, boot: nil)
        var mounted = [MountedVolume(id: "uuid:A", name: "A", path: root + "/A", isNetwork: false),
                       MountedVolume(id: "uuid:B", name: "B", path: root + "/B", isNetwork: false)]
        indexes.mounted = { mounted }
        indexes.apply(bootOn: false, chosen: [IndexedVolume(id: "uuid:A", name: "A", isNetwork: false)], rescanHours: 6)
        let a = try #require(indexes.index(forVolume: "uuid:A"))
        #expect(indexes.index(forVolume: "uuid:B") == nil)
        #expect(indexes.active.covering(root + "/A/x") === a)
        try await waitReady(a)

        // Unmounted: stopped, file kept. Mounted again: running again.
        mounted.removeFirst()
        indexes.volumesChanged()
        #expect(indexes.index(forVolume: "uuid:A") == nil)
        #expect(indexes.active.all.isEmpty)
        for _ in 0..<100 where !fm.fileExists(atPath: SearchIndexes.file(for: "uuid:A", in: folder).path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(fm.fileExists(atPath: SearchIndexes.file(for: "uuid:A", in: folder).path))
        mounted.insert(MountedVolume(id: "uuid:A", name: "A", path: root + "/A", isNetwork: false), at: 0)
        indexes.volumesChanged()
        let back = try #require(indexes.index(forVolume: "uuid:A"))
        try await waitReady(back)

        // Unticked: stopped and its file deleted.
        indexes.apply(bootOn: false, chosen: [], rescanHours: 6)
        #expect(indexes.active.all.isEmpty)
        for _ in 0..<100 where fm.fileExists(atPath: SearchIndexes.file(for: "uuid:A", in: folder).path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!fm.fileExists(atPath: SearchIndexes.file(for: "uuid:A", in: folder).path))
    }

    @Test func volumeIdentities() {
        #expect(MountedVolume.identity(isNetwork: false, uuid: "ab-cd", remountURL: nil, name: "X") == "uuid:AB-CD")
        #expect(MountedVolume.identity(isNetwork: true, uuid: nil, remountURL: URL(string: "smb://alice:secret@nas/Media"), name: "Media")
                == "url:smb://alice@nas/Media")
        #expect(MountedVolume.identity(isNetwork: false, uuid: nil, remountURL: nil, name: "FAT") == "name:FAT")
    }
}
