// File operations that run in the queue: copy, move, delete (or move to the Trash), new folder
// and rename. The UI builds them; they never touch the UI and ask questions only through
// `OperationContext.ask`.

import BasilCore
import BasilVFS
import Foundation
import Synchronization

func itemsText(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

/// Asks Retry / Skip / Skip All / Cancel when one item of an operation fails. "Skip All" is
/// remembered for the rest of the operation.
final class ItemErrorPolicy: Sendable {
    private let context: OperationContext
    private let action: String
    private let skipAll = Mutex(false)

    init(context: OperationContext, action: String) {
        self.context = context
        self.action = action
    }

    func handle(_ error: any Error, at path: VFSPath) async throws -> ItemErrorDecision {
        if error is CancellationError || context.isCancelled { throw CancellationError() }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if skipAll.withLock({ $0 }) {
            context.log("Skipped \(path.path): \(reason)")
            return .skip
        }
        let answer = await context.ask(.itemFailed(ItemFailure(path: path, action: action, reason: reason)))
        guard case .itemFailed(let choice) = answer else { throw CancellationError() }
        switch choice {
        case .retry:
            return .retry
        case .skip:
            context.log("Skipped \(path.path): \(reason)")
            return .skip
        case .skipAll:
            skipAll.withLock { $0 = true }
            context.log("Skipped \(path.path): \(reason)")
            return .skip
        case .cancel:
            throw CancellationError()
        case .fail:
            throw error
        }
    }

    /// Runs `body` until it succeeds or the user skips it (false).
    func run(_ path: VFSPath, _ body: () async throws -> Void) async throws -> Bool {
        while true {
            do {
                try await body()
                return true
            } catch let error as CancellationError {
                throw error
            } catch {
                switch try await handle(error, at: path) {
                case .retry: context.log("Retrying \(path.path)")
                case .skip: return false
                }
            }
        }
    }
}

/// F5 / F6: copies or moves items with the secure copy engine (or its Total Commander style mode).
public struct TransferOperation: QueueOperation {
    public let mode: TransferMode
    public let sources: [VFSPath]
    /// An existing folder to copy into, or for a single source the full new path. A path that
    /// does not exist with several sources is created as a folder.
    public let target: VFSPath
    /// Shift+F5: each source is copied next to itself as "name (2).ext" (the first free number);
    /// `target` is not used.
    public let duplicate: Bool
    let registry: ProviderRegistry
    let options: SecureCopyOptions

    public init(mode: TransferMode, sources: [VFSPath], target: VFSPath, registry: ProviderRegistry, options: SecureCopyOptions) {
        self.mode = mode
        self.sources = sources
        self.target = target
        self.duplicate = false
        self.registry = registry
        self.options = options
    }

    /// Copies each source into its own folder under a free "name (2).ext" name.
    public init(duplicating sources: [VFSPath], registry: ProviderRegistry, options: SecureCopyOptions) {
        self.mode = .copy
        self.sources = sources
        self.target = sources.first?.parent ?? VFSPath(location: .local, path: "/")
        self.duplicate = true
        self.registry = registry
        self.options = options
    }

    public var kind: OperationKind { mode == .copy ? .copy : .move }

    public var title: String {
        let what = sources.count == 1 ? sources[0].name : itemsText(sources.count)
        if duplicate { return "Duplicate \(what)" }
        return "\(mode == .copy ? "Copy" : "Move") \(what) to \(target.path)"
    }

    public func run(_ context: OperationContext) async throws {
        _ = try await transferAll(context)
    }

    /// Runs the transfers and returns the sources that were transferred completely (nothing
    /// inside them failed or was skipped).
    func transferAll(_ context: OperationContext) async throws -> [VFSPath] {
        let dst = try registry.writableProvider(for: target.location)
        let targetKind = duplicate ? nil : try? await dst.fingerprint(of: target).kind
        var pairs: [(VFSPath, VFSPath)]
        if duplicate {
            pairs = []
            var taken: Set<VFSPath> = []
            for source in sources {
                guard let parent = source.parent else { throw VFSError.unsupported("Duplicate \(source.path)") }
                let provider = try registry.writableProvider(for: source.location)
                let isFolder = (try? await provider.fingerprint(of: source).kind) == .directory
                let name = try await FreeName.find(for: source, folder: isFolder, provider: provider, taken: taken)
                let destination = parent.appending(name)
                taken.insert(destination)
                pairs.append((source, destination))
            }
        } else if targetKind == .directory {
            pairs = sources.map { ($0, target.appending($0.name)) }
        } else if sources.count == 1 {
            pairs = [(sources[0], target)]
        } else {
            if targetKind != nil { throw VFSError.notADirectory(target) }
            try await dst.makeDirectory(target)
            context.log("Created folder \(target.path)")
            pairs = sources.map { ($0, target.appending($0.name)) }
        }

        context.items(done: 0, total: pairs.count)
        context.progress(nil, "Counting")
        var counting = TransferProgress()
        context.transfer(counting, force: true)
        var total: Int64 = 0
        var files = 0
        var counts: [(bytes: Int64, files: Int)] = []
        for (source, _) in pairs {
            let c = try await Self.count(source, registry, context) { bytes, n in
                counting.bytesTotal = total + bytes
                counting.filesTotal = files + n
                context.transfer(counting)
            }
            counts.append(c)
            total += c.bytes
            files += c.files
        }

        let errors = ItemErrorPolicy(context: context, action: mode == .copy ? "copy" : "move")
        let monitor = QueueTransferMonitor(context: context, registry: registry, totalBytes: total, totalFiles: files,
                                           errors: errors)
        let engine = SecureCopyEngine(registry: registry, options: options, monitor: monitor)
        context.log(options.secure ? "Secure mode" : "Total Commander style mode")
        var done = 0
        var complete: [VFSPath] = []
        var settledBytes: Int64 = 0
        var settledFiles = 0
        for (index, (source, destination)) in pairs.enumerated() {
            defer {
                settledBytes += counts[index].bytes
                settledFiles += counts[index].files
                monitor.settle(bytes: settledBytes, files: settledFiles)
            }
            try await context.checkpoint()
            monitor.setLabel("\(index + 1) of \(pairs.count), \(source.name)")
            // Item-level errors are asked about inside the engine; this catches the ones before
            // it starts (the source is gone, a folder into itself, ...).
            var summary = TransferSummary()
            guard try await errors.run(source, { summary = try await engine.transfer(source, to: destination, mode: mode) })
            else { continue }
            for p in summary.skipped { context.log("Skipped \(p.path)") }
            for p in summary.acceptedUnstable { context.log("Accepted while still changing: \(p.path)") }
            for p in summary.sourcesKept { context.log("Kept source \(p.path)") }
            if summary.failed.isEmpty, summary.files + summary.directories + summary.symlinks > 0 { done += 1 }
            if summary.failed.isEmpty, summary.skipped.isEmpty { complete.append(source) }
            context.items(done: done, total: pairs.count)
        }
        context.progress(1, "\(itemsText(done)) \(mode == .copy ? "copied" : "moved")")
        return complete
    }

    /// Bytes of a file, or of all files below a folder.
    static func size(of path: VFSPath, _ registry: ProviderRegistry, _ context: OperationContext) async throws -> Int64 {
        try await count(path, registry, context).bytes
    }

    /// Bytes and regular files of a file, or of everything below a folder (symlinks not
    /// followed). `found` hears the running totals of this path while folders are walked.
    static func count(_ path: VFSPath, _ registry: ProviderRegistry, _ context: OperationContext,
                      found: (Int64, Int) -> Void = { _, _ in }) async throws -> (bytes: Int64, files: Int) {
        let provider = try registry.provider(for: path.location)
        let item = try await provider.item(at: path)
        switch item.kind {
        case .directory: break
        case .file: return (item.size ?? 0, 1)
        default: return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        var folders = [path]
        while let folder = folders.popLast() {
            for try await batch in provider.list(folder) {
                try await context.checkpoint()
                for child in batch {
                    switch child.kind {
                    case .directory: folders.append(child.path)
                    case .file:
                        bytes += child.size ?? 0
                        files += 1
                    default: break
                    }
                }
                found(bytes, files)
            }
        }
        return (bytes, files)
    }
}

/// Connects the copy engine to a queue item: progress (with speed, time left and the current
/// file), log, and the conflict and changing-source questions (remembering "all" answers for the
/// rest of the operation).
public final class QueueTransferMonitor: TransferMonitor {
    private struct State {
        /// First-pass bytes really transferred (the speed and the estimate use only these).
        var bytes: Int64 = 0
        /// Bytes of files skipped, failed or moved at once with their folder: done, not transferred.
        var settled: Int64 = 0
        /// First-pass bytes of the current file, taken back when it is retried or skipped.
        var current: Int64 = 0
        var currentSize: Int64 = 0
        var currentOpen = false
        var files = 0
        var label = ""
        var remembered: ConflictChoice?
        var progress = TransferProgress()
        var estimator = TransferEstimator()
    }

    private let context: OperationContext
    private let registry: ProviderRegistry
    private let totalBytes: Int64
    private let errors: ItemErrorPolicy
    private let state = Mutex(State())

    init(context: OperationContext, registry: ProviderRegistry, totalBytes: Int64, totalFiles: Int = 0,
         errors: ItemErrorPolicy) {
        self.context = context
        self.registry = registry
        self.totalBytes = totalBytes
        self.errors = errors
        state.withLock {
            $0.progress.bytesTotal = totalBytes
            $0.progress.filesTotal = totalFiles
            $0.progress.phase = .transferring
        }
    }

    /// For operations outside this package (and the Debug menu's fake transfer).
    public convenience init(context: OperationContext, registry: ProviderRegistry, totalBytes: Int64,
                            totalFiles: Int, action: String) {
        self.init(context: context, registry: registry, totalBytes: totalBytes, totalFiles: totalFiles,
                  errors: ItemErrorPolicy(context: context, action: action))
    }

    public func handleError(_ error: any Error, at path: VFSPath) async throws -> ItemErrorDecision {
        try await errors.handle(error, at: path)
    }

    public func setLabel(_ label: String) {
        state.withLock { $0.label = label }
        report()
    }

    public func checkpoint() async throws { try await context.checkpoint() }
    public func log(_ message: String) { context.log(message) }

    public func transferred(bytes: Int64) {
        state.withLock {
            $0.bytes += bytes
            if $0.currentOpen { $0.current += bytes }
        }
        report()
    }

    public func fileStarted(_ source: VFSPath, to destination: VFSPath, size: Int64) {
        let now = context.activeSeconds
        state.withLock { s in
            if s.currentOpen {
                // A retry of the same file: its bytes are counted again from the start.
                s.bytes -= s.current
            } else {
                s.estimator.fileStarted(time: now)
            }
            s.current = 0
            s.currentSize = size
            s.currentOpen = true
            s.progress.source = source
            s.progress.destination = destination
            s.progress.fileBytesTotal = size
            s.progress.fileBytesDone = 0
            s.progress.phase = .transferring
        }
        report(force: true)
    }

    public func fileProgress(bytes: Int64) {
        state.withLock { $0.progress.fileBytesDone = bytes }
        report()
    }

    public func phase(_ phase: TransferProgress.Phase) {
        state.withLock { $0.progress.phase = phase }
        report(force: true)
    }

    public func fileFinished(skipped: Bool) {
        let now = context.activeSeconds
        state.withLock { s in
            guard s.currentOpen else { return }
            if skipped {
                s.bytes -= s.current
                s.settled += s.currentSize
            } else if s.current < s.currentSize {
                // The file shrank while it was copied: the rest of its counted size is done anyway.
                s.settled += s.currentSize - s.current
            }
            s.estimator.record(time: now, bytes: s.bytes)
            if !skipped { s.estimator.fileFinished(time: now, bytes: s.current) }
            s.files += 1
            s.currentOpen = false
            s.current = 0
        }
        report(force: true)
    }

    /// After a top-level item: everything counted for the items so far is done, also what moved
    /// at once with its folder or was left out before the engine saw it.
    public func settle(bytes: Int64, files: Int) {
        state.withLock { s in
            let done = s.bytes + s.settled
            if bytes > done { s.settled += bytes - done }
            if files > s.files { s.files = files }
        }
        report(force: true)
    }

    private func report(force: Bool = false) {
        let now = context.activeSeconds
        let (label, progress) = state.withLock { s -> (String, TransferProgress) in
            s.estimator.record(time: now, bytes: s.bytes)
            var p = s.progress
            p.bytesDone = min(max(0, s.bytes + s.settled), max(totalBytes, s.bytes + s.settled))
            if p.bytesTotal < p.bytesDone { p.bytesTotal = p.bytesDone }
            p.filesDone = s.files
            p.elapsed = now
            p.bytesPerSecond = s.estimator.speed(at: now)
            let filesLeft = max(0, p.filesTotal - s.files)
            p.secondsLeft = s.estimator.secondsLeft(at: now, bytesLeft: max(0, p.bytesTotal - p.bytesDone),
                                                    filesLeft: p.filesTotal > 0 ? filesLeft : 0)
            s.progress = p
            return (s.label, p)
        }
        let fraction = progress.fraction ?? (totalBytes > 0 ? 0 : nil)
        context.progress(fraction == 1 ? 0.999 : fraction, label)
        context.transfer(progress, force: force)
    }

    public func decide(_ source: UnstableSource) async -> UnstableSourceDecision {
        if case .unstableSource(let decision) = await context.ask(.unstableSource(source)) { return decision }
        return .cancel
    }

    public func resolveConflict(_ conflict: FileConflict) async throws -> ConflictResolution {
        let choice: ConflictChoice
        if let remembered = state.withLock({ $0.remembered }) {
            choice = remembered
        } else {
            guard case .conflict(let answer) = await context.ask(.conflict(conflict)) else { throw CancellationError() }
            choice = answer
            if [.overwriteAll, .overwriteAllOlder, .skipAll].contains(answer) {
                state.withLock { $0.remembered = answer }
            }
        }
        switch choice {
        case .overwrite, .overwriteAll: return .overwrite
        case .skip, .skipAll: return .skip
        case .overwriteAllOlder:
            let older = (conflict.destinationFingerprint.modifiedNanos ?? .min) < (conflict.sourceFingerprint.modifiedNanos ?? .min)
            return older ? .overwrite : .skip
        case .rename:
            return .rename(try await freeName(for: conflict.destination))
        case .cancel:
            throw CancellationError()
        }
    }

    /// "name (2).ext", "name (3).ext", ... the first that does not exist.
    private func freeName(for path: VFSPath) async throws -> String {
        try await FreeName.find(for: path, folder: false, provider: registry.writableProvider(for: path.location))
    }
}

/// The first free "name (2).ext", "name (3).ext", ... next to a path. Folders keep dots in their
/// names ("Photos.2024 (2)").
enum FreeName {
    static func find(for path: VFSPath, folder: Bool, provider: any WritableProvider,
                     taken: Set<VFSPath> = []) async throws -> String {
        let name = path.name
        let dot = folder ? nil : name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        guard let parent = path.parent else { return name }
        for n in 2... {
            let candidate = parent.appending("\(base) (\(n))\(ext)")
            if taken.contains(candidate) { continue }
            if (try? await provider.fingerprint(of: candidate)) == nil { return candidate.name }
        }
        return name
    }
}

/// F8: moves items to the Trash, or deletes them permanently (Shift+F8).
public struct DeleteOperation: QueueOperation {
    public let paths: [VFSPath]
    public let toTrash: Bool
    let registry: ProviderRegistry

    public init(paths: [VFSPath], toTrash: Bool, registry: ProviderRegistry) {
        self.paths = paths
        self.toTrash = toTrash
        self.registry = registry
    }

    public var kind: OperationKind { toTrash ? .trash : .delete }

    public var title: String {
        let what = paths.count == 1 ? paths[0].name : itemsText(paths.count)
        return toTrash ? "Move \(what) to the Trash" : "Delete \(what)"
    }

    public func run(_ context: OperationContext) async throws {
        context.items(done: 0, total: paths.count)
        let errors = ItemErrorPolicy(context: context, action: toTrash ? "move to the Trash" : "delete")
        var done = 0
        for (index, path) in paths.enumerated() {
            try await context.checkpoint()
            context.progress(Double(index) / Double(paths.count), "\(index + 1) of \(paths.count), \(path.name)")
            let removed: Bool
            if toTrash {
                removed = try await errors.run(path) {
                    try await registry.writableProvider(for: path.location).trash(path)
                }
            } else {
                removed = try await Self.removeTree(path, registry, errors, context)
            }
            guard removed else { continue }
            done += 1
            context.log(toTrash ? "Moved \(path.path) to the Trash" : "Deleted \(path.path)")
            context.items(done: done, total: paths.count)
        }
        context.progress(1, "\(itemsText(done)) \(toTrash ? "moved to the Trash" : "deleted")")
    }

    /// Deletes a file or a folder with everything in it. False when something was skipped
    /// after an error (the folders above it are then kept too).
    static func removeTree(_ path: VFSPath, _ registry: ProviderRegistry, _ errors: ItemErrorPolicy,
                           _ context: OperationContext) async throws -> Bool {
        try await context.checkpoint()
        let provider = try registry.writableProvider(for: path.location)
        var children: [FileItem] = []
        guard try await errors.run(path, {
            children = []
            guard try await provider.fingerprint(of: path).kind == .directory else { return }
            for try await batch in provider.list(path) { children += batch }
        }) else { return false }
        var complete = true
        for child in children {
            if try await !removeTree(child.path, registry, errors, context) { complete = false }
        }
        guard complete else { return false }
        return try await errors.run(path) { try await provider.remove(path) }
    }
}

/// F7: creates one folder.
public struct MakeDirectoryOperation: QueueOperation {
    public let path: VFSPath
    let registry: ProviderRegistry

    public init(path: VFSPath, registry: ProviderRegistry) {
        self.path = path
        self.registry = registry
    }

    public var kind: OperationKind { .makeDirectory }
    public var title: String { "New folder \(path.name)" }

    public func run(_ context: OperationContext) async throws {
        context.items(done: 0, total: 1)
        try await registry.writableProvider(for: path.location).makeDirectory(path)
        context.items(done: 1, total: 1)
        context.log("Created \(path.path)")
    }
}

/// Shift+F4: creates an empty file (fails if anything exists at the path).
public struct NewFileOperation: QueueOperation {
    public let path: VFSPath
    let registry: ProviderRegistry

    public init(path: VFSPath, registry: ProviderRegistry) {
        self.path = path
        self.registry = registry
    }

    public var kind: OperationKind { .newFile }
    public var title: String { "New file \(path.name)" }

    public func run(_ context: OperationContext) async throws {
        context.items(done: 0, total: 1)
        let file = try await registry.writableProvider(for: path.location).createFile(path)
        // createFile makes owner-only files (it is meant for partial copies); a new file gets the usual rw-r--r--.
        let warnings = (try? await file.apply(FileMetadata(permissions: 0o644))) ?? []
        await file.close()
        warnings.forEach(context.log)
        context.items(done: 1, total: 1)
        context.log("Created \(path.path)")
    }
}

/// Shift+F6: renames one item in place.
public struct RenameOperation: QueueOperation {
    public let source: VFSPath
    public let destination: VFSPath
    let registry: ProviderRegistry

    public init(source: VFSPath, destination: VFSPath, registry: ProviderRegistry) {
        self.source = source
        self.destination = destination
        self.registry = registry
    }

    public var kind: OperationKind { .rename }
    public var title: String { "Rename \(source.name) to \(destination.name)" }

    public func run(_ context: OperationContext) async throws {
        context.items(done: 0, total: 1)
        let provider = try registry.writableProvider(for: source.location)
        // A change of case only ("a.txt" to "A.txt") on a case-insensitive volume finds the
        // item itself at the new name; that is not a conflict.
        var replacing = false
        if source.path.lowercased() == destination.path.lowercased(),
           let a = try? await provider.fingerprint(of: source), let b = try? await provider.fingerprint(of: destination),
           a.fileID != nil, a.fileID == b.fileID {
            replacing = true
        }
        try await provider.rename(source, to: destination, replacing: replacing)
        context.items(done: 1, total: 1)
        context.log("Renamed \(source.path) to \(destination.name)")
    }
}

/// Cmd+M: renames many items in one go (the Multi-Rename tool). Items whose new name is the
/// current name of another item in the batch (a swap such as a -> b, b -> a, or a change of case
/// only) first get a temporary name, so nothing is overwritten. The renames that were done are
/// written to an undo log; undoing runs the reverse batch and removes the log.
public struct MultiRenameOperation: QueueOperation {
    public struct Pair: Codable, Sendable, Equatable {
        public let source: VFSPath
        public let destination: VFSPath

        public init(source: VFSPath, destination: VFSPath) {
            self.source = source
            self.destination = destination
        }
    }

    public let pairs: [Pair]
    /// Where the renames done are recorded for undo (nil: no log). For an undo batch, the log
    /// it undoes, which is removed once it has run.
    public let undoLog: URL?
    public let isUndo: Bool
    let registry: ProviderRegistry

    public init(pairs: [Pair], undoLog: URL?, registry: ProviderRegistry) {
        self.pairs = pairs.filter { $0.source != $0.destination }
        self.undoLog = undoLog
        self.isUndo = false
        self.registry = registry
    }

    /// The batch that reverses the one recorded in `log`; nil when there is no log to undo.
    public static func undo(log: URL, registry: ProviderRegistry) -> MultiRenameOperation? {
        guard let done = readLog(log), !done.isEmpty else { return nil }
        return MultiRenameOperation(undoing: done.reversed().map { Pair(source: $0.destination, destination: $0.source) },
                                    log: log, registry: registry)
    }

    private init(undoing pairs: [Pair], log: URL, registry: ProviderRegistry) {
        self.pairs = pairs
        self.undoLog = log
        self.isUndo = true
        self.registry = registry
    }

    public static func readLog(_ url: URL) -> [Pair]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Pair].self, from: data)
    }

    public var kind: OperationKind { .rename }
    public var title: String {
        isUndo ? "Undo rename of \(itemsText(pairs.count))" : "Rename \(itemsText(pairs.count))"
    }

    public func run(_ context: OperationContext) async throws {
        let errors = ItemErrorPolicy(context: context, action: "rename")
        let total = pairs.count
        context.items(done: 0, total: total)
        let sources = Set(pairs.map { $0.source.path.lowercased() })
        var done: [Pair] = []
        // Pairs still to finish: where the item is now, and where it goes.
        var pending: [(current: VFSPath, pair: Pair)] = []
        do {
            // Phase 1: items whose target is taken by an item of the batch move to a temporary name.
            for pair in pairs {
                try await context.checkpoint()
                let provider = try registry.writableProvider(for: pair.source.location)
                guard sources.contains(pair.destination.path.lowercased()), let parent = pair.source.parent else {
                    pending.append((pair.source, pair))
                    continue
                }
                let temp = parent.appending(".basil-rename-\(UUID().uuidString)")
                if try await errors.run(pair.source, { try await provider.rename(pair.source, to: temp, replacing: false) }) {
                    pending.append((temp, pair))
                }
            }
            // Phase 2: everything to its new name.
            for (index, entry) in pending.enumerated() {
                try await context.checkpoint()
                context.progress(Double(index) / Double(max(1, pending.count)),
                                 "\(index + 1) of \(pending.count), \(entry.pair.source.name)")
                let provider = try registry.writableProvider(for: entry.current.location)
                let renamed = try await errors.run(entry.pair.source) {
                    try await provider.rename(entry.current, to: entry.pair.destination, replacing: false)
                }
                if renamed {
                    done.append(entry.pair)
                    context.log("Renamed \(entry.pair.source.path) to \(entry.pair.destination.name)")
                    context.items(done: done.count, total: total)
                } else if entry.current != entry.pair.source {
                    try await restore(entry.current, to: entry.pair.source, provider, context)
                }
            }
        } catch {
            // Cancelled or failed half way: items left under a temporary name go back to their old name.
            for entry in pending where entry.current != entry.pair.source && !done.contains(entry.pair) {
                if let provider = try? registry.writableProvider(for: entry.current.location) {
                    try? await restore(entry.current, to: entry.pair.source, provider, context)
                }
            }
            writeLog(done)
            throw error
        }
        writeLog(done)
        context.progress(1, "\(itemsText(done.count)) renamed")
    }

    private func restore(_ temp: VFSPath, to original: VFSPath, _ provider: any WritableProvider,
                         _ context: OperationContext) async throws {
        do {
            try await provider.rename(temp, to: original, replacing: false)
            context.log("Kept the old name of \(original.path)")
        } catch {
            context.log("Could not give \(temp.path) its old name \(original.name) back: \(error.localizedDescription)")
        }
    }

    /// A normal batch records what it renamed; an undo removes the log it has undone (a partial
    /// undo keeps the part that is still to undo).
    private func writeLog(_ done: [Pair]) {
        guard let undoLog else { return }
        if isUndo {
            let undone = Set(done.map { $0.destination.path })
            let remaining = (Self.readLog(undoLog) ?? []).filter { !undone.contains($0.source.path) }
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: undoLog)
            } else if let data = try? JSONEncoder().encode(remaining) {
                try? data.write(to: undoLog, options: .atomic)
            }
            return
        }
        guard !done.isEmpty, let data = try? JSONEncoder().encode(done) else { return }
        try? FileManager.default.createDirectory(at: undoLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: undoLog, options: .atomic)
    }
}
