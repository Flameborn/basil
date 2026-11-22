import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Option+Shift+F9 (Total Commander's Alt+Shift+F9): reads every entry of the archives and
/// checks them. Fails when any archive has problems; the log lists each one.
public struct TestArchiveOperation: QueueOperation {
    public let archives: [VFSPath]
    let registry: ProviderRegistry

    public init(archives: [VFSPath], registry: ProviderRegistry) {
        self.archives = archives
        self.registry = registry
    }

    public var kind: OperationKind { .testArchive }
    public var title: String {
        archives.count == 1 ? "Test \(archives[0].name)" : "Test \(archives.count) archives"
    }

    public struct Problems: LocalizedError {
        public let count: Int
        public let archives: Int
        public var errorDescription: String? {
            let problems = count == 1 ? "1 problem" : "\(count) problems"
            return archives == 1 ? "\(problems) found" : "\(problems) found in \(archives) archives"
        }
    }

    public func run(_ context: OperationContext) async throws {
        var problems = 0
        var damaged = 0
        context.items(done: 0, total: archives.count)
        for (n, archive) in archives.enumerated() {
            try await context.checkpoint()
            guard let opener = registry.containerOpener(forFile: archive) else {
                context.log("\(archive.name): not an archive")
                problems += 1
                damaged += 1
                continue
            }
            let total = archives.count
            do {
                let found = try await opener.test(archive, registry: registry) { fraction, entry in
                    context.progress((Double(n) + fraction) / Double(total), entry)
                }
                for problem in found { context.log("\(archive.name): \(problem)") }
                if found.isEmpty { context.log("\(archive.name): no problems") }
                problems += found.count
                if !found.isEmpty { damaged += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.log("\(archive.name): \(error.localizedDescription)")
                problems += 1
                damaged += 1
            }
            context.items(done: n + 1, total: total)
        }
        if problems > 0 { throw Problems(count: problems, archives: damaged) }
    }
}

/// Connects a container writer to a queue item: progress by bytes, the log, and the
/// Retry / Skip / Skip All / Cancel question when a source can't be read.
final class QueueWriteMonitor: ContainerWriteMonitor {
    private let context: OperationContext
    private let errors: ItemErrorPolicy
    private let total: Int64
    private let state = Mutex((bytes: Int64(0), label: ""))

    init(context: OperationContext, errors: ItemErrorPolicy, totalBytes: Int64) {
        self.context = context
        self.errors = errors
        self.total = totalBytes
    }

    func setLabel(_ label: String) {
        state.withLock { $0.label = label }
        report()
    }

    func checkpoint() async throws { try await context.checkpoint() }
    func log(_ message: String) { context.log(message) }

    func written(bytes: Int64) {
        state.withLock { $0.bytes += bytes }
        report()
    }

    private func report() {
        let (bytes, label) = state.withLock { ($0.bytes, $0.label) }
        let fraction = total > 0 ? min(0.999, Double(bytes) / Double(total)) : nil
        context.progress(fraction, label)
    }

    func skipAfterError(_ error: any Error, at source: VFSPath) async throws -> Bool {
        try await errors.handle(error, at: source) == .skip
    }
}

/// Shared steps of the archive operations.
enum ArchiveSteps {
    /// Turns `sources` into adds below `folder` inside an archive (or the root of a new one).
    /// With `existing`, files that are already in the archive are asked about (Total Commander's
    /// conflict question); skipped ones are left out, renamed ones get a free name.
    static func adds(for sources: [VFSPath], into folder: String, paths: Bool, existing: ProviderLocation?,
                     registry: ProviderRegistry, context: OperationContext,
                     conflicts: QueueTransferMonitor?) async throws -> (changes: [ContainerChange], left: [VFSPath]) {
        var duplicates: [VFSPath] = [], used = Set<String>()
        var changes: [ContainerChange] = []
        for source in sources {
            try await context.checkpoint()
            let at = (folder == "/" ? "/" : folder + "/") + source.name
            changes += try await ContainerChange.adds(for: source, at: at, paths: paths, registry: registry,
                                                      duplicates: &duplicates, used: &used)
        }
        for d in duplicates { context.log("Left out \(d.path): the archive already gets a file with that name") }
        guard let existing, let conflicts else { return (changes, duplicates) }
        let archive = try registry.writableProvider(for: existing)
        var result: [ContainerChange] = []
        var left = duplicates
        var skippedFolders: [String] = []
        for change in changes {
            guard let at = change.addedPath, let source = change.source else { result.append(change); continue }
            if skippedFolders.contains(where: { at.hasPrefix($0 + "/") }) { continue }
            let target = VFSPath(location: existing, path: at)
            guard let present = try? await archive.fingerprint(of: target) else { result.append(change); continue }
            if case .addDirectory = change {
                if present.kind == .directory { continue } // merge into the existing folder
                result.append(change)
                continue
            }
            let mine = try await registry.writableProvider(for: source.location).fingerprint(of: source)
            switch try await conflicts.resolveConflict(FileConflict(source: source, destination: target,
                                                                    sourceFingerprint: mine, destinationFingerprint: present)) {
            case .overwrite, .fail:
                result.append(change)
            case .skip:
                left.append(source)
                context.log("Skipped \(source.name): it is already in the archive")
            case .rename(let name):
                let renamed = ArchivePaths.parent(of: at) == "/" ? "/" + name : ArchivePaths.parent(of: at) + "/" + name
                switch change {
                case .addFile: result.append(.addFile(source: source, at: renamed))
                case .addSymlink: result.append(.addSymlink(source: source, at: renamed))
                default: result.append(change)
                }
            }
        }
        return (result, left)
    }

    /// Writes, and writes again while sources keep changing (the unstable-source policy). Returns
    /// the sources whose entries may not match them (accepted while still changing).
    static func writeStable(retries: Int, context: OperationContext,
                            _ write: () async throws -> ContainerWriteResult) async throws -> (ContainerWriteResult, [VFSPath]) {
        var attempts = 0
        while true {
            let result = try await write()
            guard let first = result.changedSources.first else { return (result, []) }
            attempts += 1
            if attempts <= retries {
                context.log("Sources changed while they were packed, packing again (attempt \(attempts))")
                try await Task.sleep(for: .milliseconds(500 * attempts))
                continue
            }
            guard case .unstableSource(let decision) = await context.ask(.unstableSource(UnstableSource(path: first, attempts: attempts)))
            else { throw CancellationError() }
            switch decision {
            case .keepRetrying: attempts = 0
            case .acceptLatest, .skip:
                for s in result.changedSources { context.log("Accepted while still changing: \(s.path)") }
                return (result, result.changedSources)
            case .cancel: throw CancellationError()
            }
        }
    }

    static func size(of sources: [VFSPath], _ registry: ProviderRegistry, _ context: OperationContext) async throws -> Int64 {
        var total: Int64 = 0
        for s in sources { total += (try? await TransferOperation.size(of: s, registry, context)) ?? 0 }
        return total
    }

    /// Removes moved sources, except those listed in `keep` and anything below them.
    static func removeSources(_ sources: [VFSPath], keep: [VFSPath], registry: ProviderRegistry,
                              errors: ItemErrorPolicy, context: OperationContext) async throws {
        for source in sources {
            if keep.contains(where: { $0.hasPrefix(source) }) {
                context.log("Kept \(source.path): part of it was not packed as it is now")
                continue
            }
            if try await DeleteOperation.removeTree(source, registry, errors, context) {
                context.log("Removed \(source.path)")
            }
        }
    }
}

enum ArchivePaths {
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}

/// Option+F5 (Total Commander's Alt+F5): packs items into new archives, or adds them to an
/// existing archive of a kind Basil can change. "Move to archive" removes the sources once the
/// archive is written and checked.
public struct PackOperation: QueueOperation {
    public struct Job: Sendable {
        public let archive: VFSPath
        public let sources: [VFSPath]
        public init(archive: VFSPath, sources: [VFSPath]) {
            self.archive = archive
            self.sources = sources
        }
    }

    public let jobs: [Job]
    public let options: PackOptions
    public let storePaths: Bool
    public let moveSources: Bool
    public let unstableRetries: Int
    let registry: ProviderRegistry

    public init(jobs: [Job], options: PackOptions, storePaths: Bool, moveSources: Bool, unstableRetries: Int,
                registry: ProviderRegistry) {
        self.jobs = jobs
        self.options = options
        self.storePaths = storePaths
        self.moveSources = moveSources
        self.unstableRetries = unstableRetries
        self.registry = registry
    }

    public var kind: OperationKind { .pack }
    public var title: String {
        let what = jobs.count == 1 ? jobs[0].archive.name : "\(jobs.count) archives"
        return "Pack \(what)"
    }

    public func run(_ context: OperationContext) async throws {
        context.items(done: 0, total: jobs.count)
        context.progress(nil, "Counting")
        let errors = ItemErrorPolicy(context: context, action: "pack")
        let total = try await ArchiveSteps.size(of: jobs.flatMap(\.sources), registry, context)
        let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: total)
        let conflicts = QueueTransferMonitor(context: context, registry: registry, totalBytes: 0, errors: errors)
        for (n, job) in jobs.enumerated() {
            try await context.checkpoint()
            monitor.setLabel("\(n + 1) of \(jobs.count), \(job.archive.name)")
            let local = try registry.provider(for: job.archive.location)
            if let item = try? await local.item(at: job.archive) {
                // Total Commander adds to an existing archive.
                guard let root = try await registry.openContainer(item, byContent: true),
                      let writer = registry.containerWriter(for: root.location) else {
                    throw VFSError.alreadyExists(job.archive)
                }
                if let refusal = writer.updateRefusal(for: job.archive, registry: registry) { throw VFSError.unsupported(refusal) }
                let (changes, left) = try await ArchiveSteps.adds(for: job.sources, into: "/", paths: storePaths,
                                                                  existing: root.location, registry: registry,
                                                                  context: context, conflicts: conflicts)
                let (_, unstable) = try await ArchiveSteps.writeStable(retries: unstableRetries, context: context) {
                    try await writer.update(job.archive, changes: changes, macMetadata: options.macMetadata,
                                            registry: registry, monitor: monitor)
                }
                context.log("Added to \(job.archive.path)")
                if moveSources {
                    try await ArchiveSteps.removeSources(job.sources, keep: unstable + left + skippedSources(changes, job),
                                                         registry: registry, errors: errors, context: context)
                }
            } else {
                guard let writer = registry.containerWriter(forFormat: options.format) else {
                    throw VFSError.unsupported("packing as \(options.format)")
                }
                let (changes, left) = try await ArchiveSteps.adds(for: job.sources, into: "/", paths: storePaths, existing: nil,
                                                                  registry: registry, context: context, conflicts: nil)
                var replacing = false
                let (result, unstable) = try await ArchiveSteps.writeStable(retries: unstableRetries, context: context) {
                    defer { replacing = true } // a retry replaces the first attempt's archive
                    return try await writer.create(job.archive, options: options, changes: changes, replacing: replacing,
                                                   registry: registry, monitor: monitor)
                }
                context.log("Created \(job.archive.path)")
                if moveSources {
                    try await ArchiveSteps.removeSources(job.sources, keep: unstable + left + result.skipped,
                                                         registry: registry, errors: errors, context: context)
                }
            }
            context.items(done: n + 1, total: jobs.count)
        }
        context.progress(1, jobs.count == 1 ? "Packed" : "\(jobs.count) archives packed")
    }

    /// Sources not covered by any change (all skipped in the conflict question).
    private func skippedSources(_ changes: [ContainerChange], _ job: Job) -> [VFSPath] {
        let covered = Set(changes.compactMap(\.source))
        return job.sources.filter { s in !covered.contains { $0.hasPrefix(s) } }
    }
}

/// Changes inside an archive pane: F5 / F6 into it, F6 out of it, F7, F8 and Shift+F6 inside it.
/// Each one rewrites the archive once (see ContainerWriter).
public struct ArchiveUpdateOperation: QueueOperation {
    public enum Action: Sendable {
        /// F5 / F6 into a folder of the archive.
        case add(sources: [VFSPath], into: VFSPath, move: Bool)
        /// F6 out of the archive: extract, then remove what was extracted completely.
        case moveOut(sources: [VFSPath], target: VFSPath, options: SecureCopyOptions)
        case delete([VFSPath])
        case makeDirectory(VFSPath)
        case rename(from: VFSPath, to: VFSPath)
        /// Puts an edited copy back: `source` (a local file) replaces the file `entry` (F4 inside an archive).
        case update(source: VFSPath, entry: VFSPath)
    }

    public let action: Action
    public let macMetadata: Bool
    public let unstableRetries: Int
    let registry: ProviderRegistry

    public init(_ action: Action, macMetadata: Bool, unstableRetries: Int, registry: ProviderRegistry) {
        self.action = action
        self.macMetadata = macMetadata
        self.unstableRetries = unstableRetries
        self.registry = registry
    }

    /// The archive file that is changed.
    public var container: VFSPath? {
        switch action {
        case .add(_, let into, _): into.location.container
        case .moveOut(let sources, _, _): sources.first?.location.container
        case .delete(let paths): paths.first?.location.container
        case .makeDirectory(let p): p.location.container
        case .rename(let from, _): from.location.container
        case .update(_, let entry): entry.location.container
        }
    }

    public var kind: OperationKind {
        switch action {
        case .add(_, _, let move): move ? .move : .copy
        case .moveOut: .move
        case .delete: .delete
        case .makeDirectory: .makeDirectory
        case .rename: .rename
        case .update: .pack
        }
    }

    public var title: String {
        func what(_ p: [VFSPath]) -> String { p.count == 1 ? p[0].name : itemsText(p.count) }
        let archive = container?.name ?? "archive"
        return switch action {
        case .add(let s, _, let move): "\(move ? "Move" : "Copy") \(what(s)) to \(archive)"
        case .moveOut(let s, let t, _): "Move \(what(s)) to \(t.path)"
        case .delete(let p): "Delete \(what(p)) from \(archive)"
        case .makeDirectory(let p): "New folder \(p.name) in \(archive)"
        case .rename(let from, let to): "Rename \(from.name) to \(to.name)"
        case .update(_, let entry): "Update \(entry.name) in \(archive)"
        }
    }

    public func run(_ context: OperationContext) async throws {
        guard let container, let location = locationOfChanges,
              let writer = registry.containerWriter(for: location) else {
            throw VFSError.unsupported("changing this location")
        }
        if let refusal = writer.updateRefusal(for: container, registry: registry) { throw VFSError.unsupported(refusal) }
        let errors = ItemErrorPolicy(context: context, action: kind == .delete ? "delete" : "pack")
        var archiveSize: Int64 = 0
        if let item = try? await registry.provider(for: container.location).item(at: container) { archiveSize = item.size ?? 0 }

        switch action {
        case .add(let sources, let into, let move):
            context.items(done: 0, total: sources.count)
            context.progress(nil, "Counting")
            let total = try await ArchiveSteps.size(of: sources, registry, context) + archiveSize
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: total)
            let conflicts = QueueTransferMonitor(context: context, registry: registry, totalBytes: 0, errors: errors)
            let (changes, left) = try await ArchiveSteps.adds(for: sources, into: into.path, paths: true, existing: location,
                                                              registry: registry, context: context, conflicts: conflicts)
            monitor.setLabel(container.name)
            let (result, unstable) = try await ArchiveSteps.writeStable(retries: unstableRetries, context: context) {
                try await writer.update(container, changes: changes, macMetadata: macMetadata, registry: registry, monitor: monitor)
            }
            if move {
                let covered = Set(changes.compactMap(\.source))
                let untouched = sources.filter { s in !covered.contains { $0.hasPrefix(s) } }
                try await ArchiveSteps.removeSources(sources, keep: unstable + left + result.skipped + untouched,
                                                     registry: registry, errors: errors, context: context)
            }
            context.items(done: sources.count, total: sources.count)
        case .moveOut(let sources, let target, let options):
            let copy = TransferOperation(mode: .copy, sources: sources, target: target, registry: registry, options: options)
            let complete = try await copy.transferAll(context)
            guard !complete.isEmpty else { return }
            context.progress(nil, "Removing from \(container.name)")
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: archiveSize)
            _ = try await writer.update(container, changes: complete.map { .delete($0.path) }, macMetadata: macMetadata,
                                        registry: registry, monitor: monitor)
            for s in sources where !complete.contains(s) { context.log("Kept \(s.name) in the archive: it was not copied completely") }
        case .delete(let paths):
            context.items(done: 0, total: paths.count)
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: archiveSize)
            monitor.setLabel(container.name)
            _ = try await writer.update(container, changes: paths.map { .delete($0.path) }, macMetadata: macMetadata,
                                        registry: registry, monitor: monitor)
            for p in paths { context.log("Deleted \(p.path) from \(container.name)") }
            context.items(done: paths.count, total: paths.count)
        case .makeDirectory(let path):
            if (try? await registry.provider(for: location).item(at: path)) != nil { throw VFSError.alreadyExists(path) }
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: archiveSize)
            _ = try await writer.update(container, changes: [.addDirectory(source: nil, at: path.path)], macMetadata: macMetadata,
                                        registry: registry, monitor: monitor)
            context.log("Created \(path.path) in \(container.name)")
        case .rename(let from, let to):
            let provider = try registry.provider(for: location)
            if from.path.lowercased() != to.path.lowercased(), (try? await provider.item(at: to)) != nil {
                throw VFSError.alreadyExists(to)
            }
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: archiveSize)
            _ = try await writer.update(container, changes: [.rename(from: from.path, to: to.path)], macMetadata: macMetadata,
                                        registry: registry, monitor: monitor)
            context.log("Renamed \(from.path) to \(to.name)")
        case .update(let source, let entry):
            context.items(done: 0, total: 1)
            let size = (try? await registry.writableProvider(for: source.location).fingerprint(of: source).size) ?? 0
            let monitor = QueueWriteMonitor(context: context, errors: errors, totalBytes: size + archiveSize)
            monitor.setLabel(container.name)
            _ = try await ArchiveSteps.writeStable(retries: unstableRetries, context: context) {
                try await writer.update(container, changes: [.addFile(source: source, at: entry.path)],
                                        macMetadata: macMetadata, registry: registry, monitor: monitor)
            }
            context.log("Updated \(entry.path) in \(container.name)")
            context.items(done: 1, total: 1)
        }
        context.progress(1, "Done")
    }

    /// The archive's provider location (where the changed entries live).
    private var locationOfChanges: ProviderLocation? {
        switch action {
        case .add(_, let into, _): into.location
        case .moveOut(let sources, _, _): sources.first?.location
        case .delete(let paths): paths.first?.location
        case .makeDirectory(let p): p.location
        case .rename(let from, _): from.location
        case .update(_, let entry): entry.location
        }
    }
}
