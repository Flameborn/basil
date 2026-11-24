import BasilCore
import BasilVFS
import CoreServices
import Foundation
import Synchronization

/// Basil's own Everything-style filename index of one folder tree (the startup disk by default).
/// The first time it scans the tree; afterwards it loads its file and replays the FSEvents
/// missed while Basil was not running (the event ID is stored with the index). Changes while
/// running come from an FSEvents stream with file events. When the history is not available
/// (dropped events, a different volume history), the affected folder is scanned again, or the
/// whole tree.
public actor FilenameIndex {
    public enum State: Sendable, Equatable {
        case off
        case loading
        /// The first scan, with the entries found so far.
        case scanning(Int)
        /// Ready, with the number of entries.
        case ready(Int)
        /// Ready (searches use the index as it is) while the tree is scanned again in the
        /// background (network volumes), with the entries found so far by that scan.
        case refreshing(Int, scanned: Int)
        case failed(String)

        public var isReady: Bool {
            switch self {
            case .ready, .refreshing: true
            default: false
            }
        }
    }

    public nonisolated let file: URL
    public nonisolated let root: String
    /// The index of a whole volume other than the startup disk: it may be mounted at another
    /// path next time (the file is chosen by the volume's identity) and is only scanned while
    /// that volume is mounted there.
    public nonisolated let isVolume: Bool
    /// A network volume: FSEvents reports only changes made from this Mac, so the tree is scanned
    /// again when it starts (the volume was mounted) and every `rescanInterval`.
    public nonisolated let isNetwork: Bool
    nonisolated let scanner: IndexScanner
    private nonisolated let stateBox = Mutex(State.off)
    private nonisolated let observers = Mutex<[@Sendable (State) -> Void]>([])

    private var store: IndexStore?
    private var watcher: FSEventsWatcher?
    private var consumer: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Changes that arrived during a scan, applied once it is done.
    private var buffered: [FSChange] = []
    private var scanning = false
    /// The running scan replaces an index that stays searchable meanwhile.
    private var refreshing = false
    private var rescanInterval: Duration?
    private var rescanTask: Task<Void, Never>?
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    /// How long changes wait before the file is written again.
    var saveDelay: Duration = .seconds(300)

    /// - Parameter file: where the index is kept.
    public init(file: URL, root: String = "/") {
        self.init(file: file, root: root, scanner: nil)
    }

    init(file: URL, root: String, scanner: IndexScanner?, isVolume: Bool = false, isNetwork: Bool = false) {
        self.file = file
        self.root = root
        self.isVolume = isVolume
        self.isNetwork = isNetwork
        self.scanner = scanner ?? (root == "/" ? .bootVolume() : IndexScanner(skippedPaths: [], devices: nil))
    }

    /// The index of the volume mounted at `root` (not the startup disk).
    public static func volume(at root: String, file: URL, isNetwork: Bool) -> FilenameIndex {
        FilenameIndex(file: file, root: root, scanner: .volume(root), isVolume: true, isNetwork: isNetwork)
    }

    /// The startup disk's index in `folder`.
    public static func bootVolume(in folder: URL) -> FilenameIndex {
        FilenameIndex(file: folder.appendingPathComponent("Startup disk.basilindex"))
    }

    public nonisolated var state: State { stateBox.withLock { $0 } }

    /// Called on every state change (from any thread).
    public nonisolated func observe(_ handler: @escaping @Sendable (State) -> Void) {
        observers.withLock { $0.append(handler) }
    }

    private func setState(_ state: State) { publish(state) }

    private nonisolated func publish(_ state: State) {
        stateBox.withLock { $0 = state }
        for handler in observers.withLock({ $0 }) { handler(state) }
    }

    /// Whether `path` (absolute) is inside the indexed tree.
    public nonisolated func covers(_ path: String) -> Bool {
        (root == "/" || path == root || path.hasPrefix(root + "/")) && scanner.covers(path)
    }

    // MARK: Starting and stopping

    /// Loads the index (replaying missed changes) or builds it.
    public func start() {
        guard watcher == nil, scanTask == nil else { return }
        setState(.loading)
        let uuid = Self.volumeUUID(of: root)
        if let loaded = try? IndexStore.read(from: file), loaded.rootPath == root || isVolume, loaded.volumeUUID == uuid,
           loaded.lastEventID > 0 {
            // A volume mounted at another path this time ("KINGSTON 1"): same tree, new root.
            loaded.rootPath = root
            store = loaded
            watch(since: loaded.lastEventID)
            setState(.ready(loaded.liveCount))
            // Network volumes and disks without an FSEvents history (disk images attached with
            // -nobrowse, some file systems) cannot say what changed meanwhile: scan them again.
            if isNetwork || (isVolume && uuid.isEmpty) { refresh() }
        } else {
            rebuild()
        }
        scheduleRescans()
    }

    /// How often a network volume is scanned again in the background (nil: only when mounted).
    public func setRescanInterval(_ interval: Duration?) {
        rescanInterval = interval
        scheduleRescans()
    }

    private func scheduleRescans() {
        rescanTask?.cancel()
        rescanTask = nil
        guard isNetwork, let interval = rescanInterval, watcher != nil || scanTask != nil else { return }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = await self.secondsUntilRescan(interval)
                try? await Task.sleep(for: .seconds(max(60, due)))
                if Task.isCancelled { return }
                await self.rescanIfDue(interval)
            }
        }
    }

    private func secondsUntilRescan(_ interval: Duration) -> Double {
        guard let store else { return 60 }
        return Double(store.scannedAt) + Double(interval.components.seconds) - Date().timeIntervalSince1970
    }

    private func rescanIfDue(_ interval: Duration) {
        guard scanTask == nil, secondsUntilRescan(interval) <= 0 else { return }
        refresh()
    }

    /// Scans the tree again in the background while searches keep using the current index, then
    /// replaces it (network volumes, whose changes from other computers FSEvents does not see).
    public func refresh() {
        guard let store, scanTask == nil else {
            if store == nil, scanTask == nil { rebuild() }
            return
        }
        guard isMountedHere() else { return }
        refreshing = true
        scanning = true
        buffered = []
        setState(.refreshing(store.liveCount, scanned: 0))
        startScan()
    }

    /// Whether the volume this index is for is still mounted at `root` (always true for folders).
    nonisolated func isMountedHere() -> Bool {
        guard isVolume, let devices = scanner.devices else { return true }
        var info = Darwin.stat()
        return lstat(root, &info) == 0 && devices.contains(info.st_dev)
    }

    /// Scans the whole tree again (Settings, Rebuild Index; or when history is lost).
    public func rebuild() {
        guard isMountedHere() else { return }
        scanTask?.cancel()
        watcher?.stop()
        watcher = nil
        consumer?.cancel()
        buffered = []
        scanning = true
        refreshing = false
        setState(.scanning(0))
        // Changes from now on are collected while scanning, then applied.
        watch(since: FSEventsGetCurrentEventId())
        startScan()
    }

    private func startScan() {
        let scanner = scanner, root = root, uuid = Self.volumeUUID(of: root)
        let current = refreshing ? store?.liveCount : nil
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let cancelled: @Sendable () -> Bool = { Task.isCancelled }
            do {
                var last = Date.distantPast
                let built = try scanner.scan(root, isCancelled: cancelled) { count in
                    guard Date().timeIntervalSince(last) > 0.5 else { return }
                    last = Date()
                    self?.publish(current.map { .refreshing($0, scanned: count) } ?? .scanning(count))
                }
                built.volumeUUID = uuid
                await self?.finishScan(built)
            } catch is CancellationError {
            } catch {
                await self?.failScan(error)
            }
        }
    }

    private func finishScan(_ built: IndexStore) {
        scanTask = nil
        scanning = false
        let wasRefreshing = refreshing
        refreshing = false
        // A volume unmounted during the scan gives an empty tree: keep what there was.
        guard isMountedHere() else {
            buffered = []
            if let store, wasRefreshing { setState(.ready(store.liveCount)) } else { setState(.failed("The volume is no longer mounted")) }
            return
        }
        built.scannedAt = Int64(Date().timeIntervalSince1970)
        store = built
        let changes = buffered
        buffered = []
        apply(changes)
        built.lastEventID = max(built.lastEventID, changes.map(\.id).max() ?? 0, FSEventsGetCurrentEventId())
        save()
        setState(.ready(built.liveCount))
    }

    private func failScan(_ error: Error) {
        scanTask = nil
        scanning = false
        buffered = []
        if refreshing, let store {
            refreshing = false
            setState(.ready(store.liveCount))
            return
        }
        setState(.failed(error.localizedDescription))
    }

    /// Stops watching and writes pending changes (when Basil quits, or the setting goes off).
    public func stop(deleting: Bool = false) {
        scanTask?.cancel()
        scanTask = nil
        rescanTask?.cancel()
        rescanTask = nil
        scanning = false
        refreshing = false
        watcher?.stop()
        watcher = nil
        consumer?.cancel()
        consumer = nil
        saveTask?.cancel()
        if deleting {
            try? FileManager.default.removeItem(at: file)
        } else if dirty {
            save()
        }
        store = deleting ? nil : store
        setState(.off)
    }

    /// Writes the index now when it has unsaved changes.
    public func saveIfNeeded() {
        if dirty { save() }
    }

    private func save() {
        guard var current = store else { return }
        if current.needsCompaction {
            current = current.compacted()
            store = current
        }
        do {
            try current.write(to: file)
            dirty = false
        } catch {
            // Kept in memory; the next save tries again.
        }
    }

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.savedLater()
        }
    }

    private func savedLater() {
        saveTask = nil
        if dirty { save() }
    }

    // MARK: Changes

    private func watch(since eventID: UInt64) {
        let (stream, continuation) = AsyncStream<[FSChange]>.makeStream()
        watcher = FSEventsWatcher(path: root, since: eventID, continuation: continuation)
        consumer = Task { [weak self] in
            for await changes in stream {
                await self?.received(changes)
            }
        }
    }

    private func received(_ changes: [FSChange]) {
        if scanning {
            buffered += changes
            // While refreshing, the index being searched stays current too.
            guard refreshing else { return }
        }
        apply(changes)
        if !scanning, let store { setState(.ready(store.liveCount)) }
    }

    /// Applies FSEvents changes to the index. Internal for tests.
    func apply(_ changes: [FSChange]) {
        guard let store else { return }
        var maxID = store.lastEventID
        for change in changes {
            maxID = max(maxID, change.id)
            let flags = Int(change.flags)
            if flags & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            let path = mapped(change.path)
            // An unmounted volume: its index is stopped and kept (`SearchIndexes`).
            if flags & kFSEventStreamEventFlagUnmount != 0 || !isMountedHere() { continue }
            if flags & kFSEventStreamEventFlagRootChanged != 0 { return rebuild() }
            if flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                if path == root { return rebuild() }
                rescan(path, in: store)
                continue
            }
            guard covers(path) else { continue }
            update(path, in: store)
        }
        store.lastEventID = maxID
        scheduleSave()
    }

    /// FSEvents names data-volume paths through /System/Volumes/Data; the index uses the firmlinks.
    private func mapped(_ raw: String) -> String {
        var path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let data = "/System/Volumes/Data"
        if root == "/", path.hasPrefix(data + "/") { path = String(path.dropFirst(data.count)) }
        return path
    }

    /// Brings one path up to date: removed, changed or added (a new folder is scanned).
    @discardableResult
    private func update(_ path: String, in store: IndexStore) -> UInt32? {
        if path == root { return 0 }
        let parentPath = (path as NSString).deletingLastPathComponent
        let existing = store.lookup(path)
        guard let (item, device) = IndexScanner.stat(path) else {
            if let existing { store.remove(existing) }
            return nil
        }
        // A parent that is not indexed yet (made just now) is added first.
        guard let parent = store.lookup(parentPath) ?? update(parentPath, in: store) else { return nil }
        let index = store.upsert(item, in: parent)
        if item.kind == IndexRecord.kindDirectory, existing != index, enters(path, device: device) {
            addTree(path, at: index, in: store)
        }
        return index
    }

    private func enters(_ path: String, device: Int32) -> Bool {
        guard covers(path), !scanner.skippedPaths.contains(path) else { return false }
        if let devices = scanner.devices { return devices.contains(device) }
        return true
    }

    /// Adds everything below a folder that was just added.
    private func addTree(_ path: String, at index: UInt32, in store: IndexStore) {
        var pending = [(index, path)]
        while let (folder, folderPath) = pending.popLast() {
            for (item, device) in (try? IndexScanner.list(folderPath)) ?? [] {
                let child = store.upsert(item, in: folder)
                let childPath = folderPath == "/" ? "/" + item.name : folderPath + "/" + item.name
                if item.kind == IndexRecord.kindDirectory, enters(childPath, device: device) { pending.append((child, childPath)) }
            }
        }
    }

    /// Scans a folder again whose changes FSEvents could not report one by one.
    private func rescan(_ path: String, in store: IndexStore) {
        guard covers(path) else { return }
        if let existing = store.lookup(path), existing != 0 { store.remove(existing) }
        update(path, in: store)
    }

    // MARK: Searching

    /// The items matching `query` below `folder`, shallow ones first. Text is not indexed.
    public func search(_ query: SearchQuery, in folder: String) throws -> [FileItem] {
        guard let store, let scope = store.lookup(folder) else { return [] }
        let matcher = try query.name.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : FoldedNameMatcher(query.name, regex: query.nameIsRegex)
        let count = store.records.count
        let parts = max(1, min(32, count / 50_000))
        let found = Mutex([[UInt32]](repeating: [], count: parts))
        let after = query.modifiedAfter.map(IndexRecord.millis), before = query.modifiedBefore.map(IndexRecord.millis)
        let checkDates = after != nil || before != nil
        store.records.withUnsafeBufferPointer { records in
            store.folded.withUnsafeBufferPointer { folded in
                nonisolated(unsafe) let records = records, folded = folded
                DispatchQueue.concurrentPerform(iterations: parts) { part in
                    var hits: [UInt32] = []
                    let range = (count * part / parts)..<(count * (part + 1) / parts)
                    for i in range where i != 0 {
                        let r = records[i]
                        if r.isRemoved { continue }
                        let isFolder = r.isDirectory
                        switch query.kinds {
                        case .filesAndFolders: break
                        case .files: if isFolder { continue }
                        case .folders: if !isFolder { continue }
                        }
                        if !query.includeHidden, r.isHidden { continue }
                        if query.minimumSize != nil || query.maximumSize != nil {
                            // A size limit finds files only.
                            guard r.kind == IndexRecord.kindFile else { continue }
                            if let minimum = query.minimumSize, r.size < minimum { continue }
                            if let maximum = query.maximumSize, r.size > maximum { continue }
                        }
                        if checkDates {
                            if r.modified == IndexRecord.unknownDate { continue }
                            if let after, r.modified < after { continue }
                            if let before, r.modified >= before { continue }
                        }
                        if let matcher {
                            if let regex = matcher.regexFilter {
                                let start = Int(r.nameOffset)
                                let name = store.names.withUnsafeBufferPointer {
                                    String(decoding: UnsafeBufferPointer(rebasing: $0[start..<start + Int(r.nameLength)]), as: UTF8.self)
                                }
                                if !regex.matches(name) { continue }
                            } else {
                                let start = Int(r.foldedOffset)
                                let name = UnsafeBufferPointer(rebasing: folded[start..<start + Int(r.foldedLength)])
                                if !matcher.matches(folded: name) { continue }
                            }
                        }
                        hits.append(UInt32(i))
                    }
                    found.withLock { $0[part] = hits }
                }
            }
        }
        var items: [FileItem] = []
        for i in found.withLock({ $0 }).joined() {
            let r = store.records[Int(i)]
            if query.subfolders ? !store.isBelow(i, scope) : r.parent != scope { continue }
            var hiddenAbove = false
            guard store.isLive(i, hiddenOnTheWay: &hiddenAbove) else { continue }
            if !query.includeHidden, hiddenAbove { continue }
            items.append(Self.item(store, i))
        }
        return items
    }

    static func item(_ store: IndexStore, _ index: UInt32) -> FileItem {
        let r = store.records[Int(index)]
        let kind: FileItem.Kind = switch r.kind {
        case IndexRecord.kindFile: .file
        case IndexRecord.kindDirectory: .directory
        case IndexRecord.kindSymlink: .symlink(target: .unknown)
        default: .other
        }
        return FileItem(path: .local(store.path(index)), kind: kind, size: r.kind == IndexRecord.kindFile ? r.size : nil,
                        modified: IndexRecord.date(r.modified), created: IndexRecord.date(r.created),
                        permissions: r.permissions, isHidden: r.isHidden)
    }

    // MARK: Volume

    /// FSEvents' identity of the volume holding `path` (the data volume for the startup disk).
    nonisolated static func volumeUUID(of path: String) -> String {
        var info = stat()
        let probe = path == "/" ? "/System/Volumes/Data" : path
        guard lstat(probe, &info) == 0 || lstat(path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? ""
    }
}

/// One FSEvents change.
struct FSChange: Sendable {
    let path: String
    let flags: UInt32
    let id: UInt64
}

/// An FSEvents stream with file events on its own queue, handing changes to a continuation.
final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Basil index events")
    let continuation: AsyncStream<[FSChange]>.Continuation

    init(path: String, since: UInt64, continuation: AsyncStream<[FSChange]>.Continuation) {
        self.continuation = continuation
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changes: [FSChange] = []
            changes.reserveCapacity(count)
            for i in 0..<min(count, list.count) { changes.append(FSChange(path: list[i], flags: flags[i], id: ids[i])) }
            watcher.continuation.yield(changes)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, since, 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
        continuation.finish()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
