import Foundation
import BasilCore
import BasilOperations
import BasilVFS

/// Local copies of files that live inside archives (later also on remotes), for F3 Quick Look and
/// F4 editing. They are kept in Basil's caches folder, which is emptied at launch and at quit.
///
/// F3 copies are extracted when the preview reaches them and reused while the archive is shown in
/// a pane. F4 copies are always fresh and are watched: when Basil becomes active again and a copy
/// has changed, the window asks once whether to put it back into the archive.
///
/// This is Basil's own scratch space, not the user's files, so the folders are created and removed
/// with FileManager directly; the files themselves are written by the copy engine through the providers.
@MainActor
final class TemporaryCopies {
    /// An F4 copy that is watched for changes.
    struct EditedCopy: Identifiable {
        let id = UUID()
        /// The file inside the archive.
        let entry: VFSPath
        /// The local copy.
        let copy: VFSPath
        /// Size and modification date when the copy was made or last put back.
        var baseline: Stamp
        /// The changed state the user answered "Not Now" for (asked again only after a further save).
        var dismissed: Stamp?
    }

    struct Stamp: Equatable {
        let size: Int64
        let modified: Int64?
    }

    let root: URL
    private let registry: ProviderRegistry
    private var previews: [VFSPath: (copy: VFSPath, size: Int64?, modified: Date?)] = [:]
    private var extracting: [VFSPath: Task<VFSPath, any Error>] = [:]
    private(set) var edits: [EditedCopy] = []
    /// Extractions in progress, by the location they read from.
    private var reading: [ProviderLocation: Int] = [:]

    init(root: URL, registry: ProviderRegistry) {
        self.root = root
        self.registry = registry
        removeAll() // left over from a crash
    }

    /// Default: ~/Library/Caches/Basil/Copies
    static var defaultRoot: URL {
        URL.cachesDirectory.appendingPathComponent("Basil/Copies", isDirectory: true)
    }

    // MARK: F3

    /// The local copy for previewing `item`, if it is already extracted and still current.
    func preview(of item: FileItem) -> VFSPath? {
        if item.path.location == .local { return item.path }
        guard let cached = previews[item.path], cached.size == item.size, cached.modified == item.modified else { return nil }
        return cached.copy
    }

    /// Extracts `item` for previewing (once; waiting callers share the extraction).
    func extractPreview(of item: FileItem) async throws -> VFSPath {
        if let ready = preview(of: item) { return ready }
        if let running = extracting[item.path] { return try await running.value }
        let task = Task { try await self.extract(item.path) }
        extracting[item.path] = task
        defer { extracting[item.path] = nil }
        let copy = try await task.value
        previews[item.path] = (copy, item.size, item.modified)
        return copy
    }

    /// Removes preview copies of archives that are not in `shown` (the containers the panes show).
    func dropPreviews(keeping shown: Set<VFSPath>) {
        for (path, cached) in previews {
            guard let container = path.location.container, !shown.contains(container) else { continue }
            previews[path] = nil
            removeFolder(of: cached.copy)
        }
    }

    // MARK: F4

    /// Extracts a fresh copy of `entry` for editing. With `watch`, it is offered for putting back.
    func extractForEditing(_ entry: VFSPath, watch: Bool) async throws -> VFSPath {
        let copy = try await extract(entry)
        if watch, let stamp = stamp(of: copy) {
            edits.append(EditedCopy(entry: entry, copy: copy, baseline: stamp))
        }
        return copy
    }

    /// Watched copies that changed since they were made or put back, and were not dismissed in this state.
    func changedEdits() -> [EditedCopy] {
        edits.filter { edit in
            guard let now = stamp(of: edit.copy) else { return false }
            return now != edit.baseline && now != edit.dismissed
        }
    }

    /// Watched copies with changes that are not in their archive.
    func unsavedEdits() -> [EditedCopy] {
        edits.filter { edit in stamp(of: edit.copy).map { $0 != edit.baseline } ?? false }
    }

    /// The current state of a watched copy, taken before it is put back.
    func currentStamp(of id: EditedCopy.ID) -> Stamp? {
        edits.first { $0.id == id }.flatMap { stamp(of: $0.copy) }
    }

    func markPutBack(_ id: EditedCopy.ID, at stamp: Stamp) {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return }
        edits[i].baseline = stamp
        edits[i].dismissed = nil
    }

    func dismiss(_ id: EditedCopy.ID) {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return }
        edits[i].dismissed = stamp(of: edits[i].copy)
    }

    /// Asks again about every changed copy (after quitting was stopped because of them).
    func clearDismissed() {
        for i in edits.indices { edits[i].dismissed = nil }
    }

    func stopWatching(_ id: EditedCopy.ID) {
        edits.removeAll { $0.id == id }
    }

    // MARK: Cleanup

    /// Locations the copies still need: watched F4 copies are put back there, extractions read from them.
    var locationsInUse: [ProviderLocation] {
        edits.map(\.entry.location) + Array(reading.keys)
    }

    /// Removes every copy (at launch and at quit).
    func removeAll() {
        for task in extracting.values { task.cancel() }
        extracting = [:]
        previews = [:]
        edits = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Private

    /// Copies one file into a new folder of its own, so names never clash.
    private func extract(_ source: VFSPath) async throws -> VFSPath {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = VFSPath.local(folder.appendingPathComponent(source.name).path)
        let engine = SecureCopyEngine(registry: registry, options: SecureCopyOptions(secure: false), monitor: QuietMonitor())
        reading[source.location, default: 0] += 1
        defer {
            reading[source.location, default: 1] -= 1
            if reading[source.location] == 0 { reading[source.location] = nil }
        }
        do {
            _ = try await engine.transfer(source, to: target, mode: .copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return target
    }

    private func removeFolder(of copy: VFSPath) {
        guard let folder = copy.parent else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: folder.path))
    }

    private func stamp(of copy: VFSPath) -> Stamp? {
        guard let values = try? URL(fileURLWithPath: copy.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate.map { Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded()) }
        return Stamp(size: Int64(size), modified: modified)
    }
}

/// Copies into the scratch folder: no progress, no questions.
private struct QuietMonitor: TransferMonitor {
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) {}
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}
