import BasilCore
import BasilOperations
import BasilVFS
import Foundation

/// Carries out a comparison's chosen actions as one queue item: copies through the secure
/// copy engine (replacing the older file, making missing folders), deletes on the right
/// (asymmetric mode) to the Trash where the place has one. A step that fails asks Retry /
/// Skip / Skip All / Cancel.
public struct SyncOperation: QueueOperation {
    public let left: VFSPath
    public let right: VFSPath
    public let entries: [SyncEntry]
    public let registry: ProviderRegistry
    public let options: SecureCopyOptions
    /// Deletes go to the Trash where the place has one (tests turn it off).
    public var useTrash = true

    public init(left: VFSPath, right: VFSPath, entries: [SyncEntry], registry: ProviderRegistry, options: SecureCopyOptions) {
        self.left = left
        self.right = right
        self.entries = entries.filter { $0.action != .none }
        self.registry = registry
        var options = options
        options.replaceExisting = true
        self.options = options
    }

    public var kind: OperationKind { .sync }
    public var title: String { "Synchronize \(left.displayName) and \(right.displayName)" }

    /// What it will do, in words: "Copy 12 files to the right (30 MB), 3 to the left, delete 2 on the right".
    public static func summary(_ entries: [SyncEntry], sizes: ByteCountFormatter.CountStyle = .file) -> String {
        func count(_ action: SyncAction) -> (Int, Int64) {
            let chosen = entries.filter { $0.action == action }
            return (chosen.reduce(0) { $0 + ($1.folderFiles ?? 1) }, chosen.reduce(0) { $0 + $1.copyBytes })
        }
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
        func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: sizes) }
        var parts: [String] = []
        let (r, rb) = count(.copyRight), (l, lb) = count(.copyLeft), (d, _) = count(.deleteRight)
        if r > 0 { parts.append("copy \(files(r)) to the right (\(bytes(rb)))") }
        if l > 0 { parts.append("copy \(files(l)) to the left (\(bytes(lb)))") }
        if d > 0 { parts.append("delete \(files(d)) on the right") }
        guard !parts.isEmpty else { return "Nothing to do" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public func run(_ context: OperationContext) async throws {
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.copyBytes }
        let totalFiles = entries.reduce(0) { $0 + ($1.action == .deleteRight ? 0 : ($1.folderFiles ?? 1)) }
        let monitor = QueueTransferMonitor(context: context, registry: registry, totalBytes: totalBytes,
                                           totalFiles: totalFiles, action: "synchronize")
        let engine = SecureCopyEngine(registry: registry, options: options, monitor: monitor)
        if options.secure {
            let providers = [left, right].compactMap { try? registry.writableProvider(for: $0.location) }
            var seen = Set<String>()
            for line in providers.flatMap({ $0.sourceCaveats + $0.destinationCaveats }) where seen.insert(line).inserted {
                context.log("Not guaranteed: \(line)")
            }
        }
        context.items(done: 0, total: entries.count)
        var failed = 0
        for (n, entry) in entries.enumerated() {
            try await context.checkpoint()
            let ok: Bool
            switch entry.action {
            case .copyRight:
                ok = try await copy(entry, from: left, to: right, engine, monitor)
            case .copyLeft:
                ok = try await copy(entry, from: right, to: left, engine, monitor)
            case .deleteRight:
                ok = try await step(right.appending(entry.relative), monitor) {
                    try await remove(right.appending(entry.relative))
                    context.log("Deleted \(entry.relative) on the right")
                }
            case .none:
                ok = true
            }
            if !ok { failed += 1 }
            context.items(done: n + 1, total: entries.count)
        }
        if failed > 0 { throw VFSError.failed("\(failed) of \(entries.count) items were skipped") }
    }

    private func copy(_ entry: SyncEntry, from source: VFSPath, to target: VFSPath, _ engine: SecureCopyEngine,
                      _ monitor: QueueTransferMonitor) async throws -> Bool {
        let from = source.appending(entry.relative), to = target.appending(entry.relative)
        return try await step(from, monitor) {
            try await makeFolders(above: to, inside: target)
            _ = try await engine.transfer(from, to: to, mode: .copy)
        }
    }

    /// Runs one step until it works or the user skips it (false).
    private func step(_ path: VFSPath, _ monitor: QueueTransferMonitor, _ body: () async throws -> Void) async throws -> Bool {
        while true {
            do {
                try await body()
                return true
            } catch let error as CancellationError {
                throw error
            } catch {
                switch try await monitor.handleError(error, at: path) {
                case .retry: continue
                case .skip: return false
                }
            }
        }
    }

    /// Makes the folders between `root` and `path` that are missing.
    private func makeFolders(above path: VFSPath, inside root: VFSPath) async throws {
        guard let parent = path.parent, parent != root, parent.hasPrefix(root) else { return }
        let provider = try registry.writableProvider(for: parent.location)
        if (try? await provider.fingerprint(of: parent))?.kind == .directory { return }
        try await makeFolders(above: parent, inside: root)
        do { try await provider.makeDirectory(parent) } catch VFSError.alreadyExists {}
    }

    /// To the Trash where the place has one, else deleted (folders with everything in them).
    private func remove(_ path: VFSPath) async throws {
        let provider = try registry.writableProvider(for: path.location)
        if useTrash, provider.capabilities.contains(.trash) {
            try await provider.trash(path)
            return
        }
        if try await provider.fingerprint(of: path).kind == .directory {
            var children: [FileItem] = []
            for try await batch in provider.list(path) { children += batch }
            for child in children { try await remove(child.path) }
        }
        try await provider.remove(path)
    }
}
