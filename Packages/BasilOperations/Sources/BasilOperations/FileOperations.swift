// File operations that run in the queue: copy, move, delete (or move to the Trash), new folder
// and rename. The UI builds them; they never touch the UI and ask questions only through
// `OperationContext.ask`.

import BasilCore
import BasilVFS
import Foundation
import Synchronization

func itemsText(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

/// F5 / F6: copies or moves items with the secure copy engine (or its Total Commander style mode).
public struct TransferOperation: QueueOperation {
    public let mode: TransferMode
    public let sources: [VFSPath]
    /// An existing folder to copy into, or for a single source the full new path. A path that
    /// does not exist with several sources is created as a folder.
    public let target: VFSPath
    let registry: ProviderRegistry
    let options: SecureCopyOptions

    public init(mode: TransferMode, sources: [VFSPath], target: VFSPath, registry: ProviderRegistry, options: SecureCopyOptions) {
        self.mode = mode
        self.sources = sources
        self.target = target
        self.registry = registry
        self.options = options
    }

    public var kind: OperationKind { mode == .copy ? .copy : .move }

    public var title: String {
        let what = sources.count == 1 ? sources[0].name : itemsText(sources.count)
        return "\(mode == .copy ? "Copy" : "Move") \(what) to \(target.path)"
    }

    public func run(_ context: OperationContext) async throws {
        let dst = try registry.writableProvider(for: target.location)
        let targetKind = try? await dst.fingerprint(of: target).kind
        let pairs: [(VFSPath, VFSPath)]
        if targetKind == .directory {
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
        var total: Int64 = 0
        for source in sources { total += try await Self.size(of: source, registry, context) }

        let monitor = QueueTransferMonitor(context: context, registry: registry, totalBytes: total)
        let engine = SecureCopyEngine(registry: registry, options: options, monitor: monitor)
        context.log(options.secure ? "Secure mode" : "Total Commander style mode")
        var done = 0
        for (index, (source, destination)) in pairs.enumerated() {
            try await context.checkpoint()
            monitor.setLabel("\(index + 1) of \(pairs.count), \(source.name)")
            let summary = try await engine.transfer(source, to: destination, mode: mode)
            for p in summary.skipped { context.log("Skipped \(p.path)") }
            for p in summary.acceptedUnstable { context.log("Accepted while still changing: \(p.path)") }
            for p in summary.sourcesKept { context.log("Kept source \(p.path)") }
            if summary.files + summary.directories + summary.symlinks > 0 { done += 1 }
            context.items(done: done, total: pairs.count)
        }
        context.progress(1, "\(itemsText(done)) \(mode == .copy ? "copied" : "moved")")
    }

    /// Bytes of a file, or of all files below a folder.
    static func size(of path: VFSPath, _ registry: ProviderRegistry, _ context: OperationContext) async throws -> Int64 {
        let provider = try registry.provider(for: path.location)
        let item = try await provider.item(at: path)
        guard item.kind == .directory else { return item.size ?? 0 }
        var total: Int64 = 0
        for try await batch in provider.list(path) {
            try await context.checkpoint()
            for child in batch {
                if child.kind == .directory {
                    total += try await size(of: child.path, registry, context)
                } else {
                    total += child.size ?? 0
                }
            }
        }
        return total
    }
}

/// Connects the copy engine to a queue item: progress, log, and the conflict and
/// changing-source questions (remembering "all" answers for the rest of the operation).
final class QueueTransferMonitor: TransferMonitor {
    private struct State {
        var bytes: Int64 = 0
        var label = ""
        var remembered: ConflictChoice?
    }

    private let context: OperationContext
    private let registry: ProviderRegistry
    private let totalBytes: Int64
    private let state = Mutex(State())

    init(context: OperationContext, registry: ProviderRegistry, totalBytes: Int64) {
        self.context = context
        self.registry = registry
        self.totalBytes = totalBytes
    }

    func setLabel(_ label: String) {
        state.withLock { $0.label = label }
        report()
    }

    func checkpoint() async throws { try await context.checkpoint() }
    func log(_ message: String) { context.log(message) }

    func transferred(bytes: Int64) {
        state.withLock { $0.bytes += bytes }
        report()
    }

    private func report() {
        let (bytes, label) = state.withLock { ($0.bytes, $0.label) }
        let fraction = totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : nil
        context.progress(fraction == 1 ? 0.999 : fraction, label)
    }

    func decide(_ source: UnstableSource) async -> UnstableSourceDecision {
        if case .unstableSource(let decision) = await context.ask(.unstableSource(source)) { return decision }
        return .cancel
    }

    func resolveConflict(_ conflict: FileConflict) async throws -> ConflictResolution {
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
        let provider = try registry.writableProvider(for: path.location)
        let name = path.name
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        guard let parent = path.parent else { return name }
        for n in 2... {
            let candidate = "\(base) (\(n))\(ext)"
            if (try? await provider.fingerprint(of: parent.appending(candidate))) == nil { return candidate }
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
        for (index, path) in paths.enumerated() {
            try await context.checkpoint()
            context.progress(Double(index) / Double(paths.count), "\(index + 1) of \(paths.count), \(path.name)")
            let provider = try registry.writableProvider(for: path.location)
            if toTrash {
                try await provider.trash(path)
            } else {
                try await removeTree(path, provider, context)
            }
            context.log(toTrash ? "Moved \(path.path) to the Trash" : "Deleted \(path.path)")
            context.items(done: index + 1, total: paths.count)
        }
        context.progress(1, "\(itemsText(paths.count)) \(toTrash ? "moved to the Trash" : "deleted")")
    }

    private func removeTree(_ path: VFSPath, _ provider: any WritableProvider, _ context: OperationContext) async throws {
        try await context.checkpoint()
        if try await provider.fingerprint(of: path).kind == .directory {
            var children: [FileItem] = []
            for try await batch in provider.list(path) { children += batch }
            for child in children { try await removeTree(child.path, provider, context) }
        }
        try await provider.remove(path)
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
