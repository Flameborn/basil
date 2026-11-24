import BasilCore
import BasilVFS
import Foundation

/// Option+F9 (Total Commander's Alt+F9): unpacks archives into a folder through the copy engine.
///
/// "Extract into its own folder" is smart: an archive with one item at the top (a folder, or a
/// single file) is unpacked straight into the target, because it already brings its own folder;
/// only an archive with several items at the top gets a folder named after it ("photos.tar.gz"
/// -> "photos", "set.part1.rar" -> "set"). Finder's `__MACOSX` and `.DS_Store` do not count as
/// items. When the folder that would be made (or the archive's own single top folder) already
/// exists, the operation asks: unpack into it, unpack into "photos (2)", skip the archive, or
/// cancel. A mask keeps only matching files, and without folder paths every file goes flat into
/// the target; both decide the top-level count from what is actually unpacked.
///
/// "Delete archive after unpacking" moves the archive (every volume of a multi-volume set) to
/// the Trash or deletes it, only when everything was unpacked without errors or skips.
public struct UnpackOperation: QueueOperation {
    public enum DeleteMode: Sendable, Equatable { case trash, permanently }

    public struct Options: Sendable {
        public var ownFolder: Bool
        /// Quick-filter syntax ("*.jpg;*.png | thumb*"); empty or "*" unpacks everything.
        public var mask: String
        /// Total Commander's "Unpack path names if stored".
        public var paths: Bool
        public var deleteAfter: DeleteMode?
        public var copy: SecureCopyOptions

        public init(ownFolder: Bool = true, mask: String = "", paths: Bool = true, deleteAfter: DeleteMode? = nil,
                    copy: SecureCopyOptions = SecureCopyOptions()) {
            self.ownFolder = ownFolder
            self.mask = mask
            self.paths = paths
            self.deleteAfter = deleteAfter
            self.copy = copy
        }
    }

    public let archives: [VFSPath]
    public let target: VFSPath
    public let options: Options
    let registry: ProviderRegistry

    public init(archives: [VFSPath], target: VFSPath, options: Options, registry: ProviderRegistry) {
        self.archives = archives
        self.target = target
        self.options = options
        self.registry = registry
    }

    public var kind: OperationKind { .unpack }
    public var title: String {
        let what = archives.count == 1 ? archives[0].name : "\(archives.count) archives"
        return "Unpack \(what) to \(target.path)"
    }

    /// Finder's metadata folder and file: never counted as top-level items.
    static let junkFolder = "__MACOSX"
    static let junkFile = ".DS_Store"

    /// The folder name for an archive: its name without archive and volume extensions.
    public static func folderName(for archiveName: String) -> String {
        var name = archiveName
        func strip(_ pattern: Regex<Substring>) {
            if let m = name.firstMatch(of: pattern), m.range.lowerBound > name.startIndex {
                name = String(name[..<m.range.lowerBound])
            }
        }
        strip(/(?i)\.(?:part\d+\.rar|r\d\d|\d{3,})$/)           // volumes: set.part1.rar, set.r00, set.7z.001
        strip(/(?i)\.(?:tgz|tbz2?|tbz|txz|tzst|tlz|taz)$/)     // short tar forms
        let before = name
        strip(/(?i)\.(?:gz|bz2|xz|zst|lz4|lzma|lz|z|Z)$/)
        if before != name { strip(/(?i)\.tar$/) }            // photos.tar.gz -> photos
        if before == name {
            strip(/(?i)\.[A-Za-z0-9]{1,8}$/)                   // photos.zip, photos.7z, photos.rar
            strip(/(?i)\.tar$/)
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? archiveName + " folder" : trimmed
    }

    /// What one archive unpacks to: source items and where each goes.
    struct Plan {
        var archive: VFSPath
        var pairs: [(source: VFSPath, destination: VFSPath)]
        /// Folders to create first (the archive's folder, folders of masked files).
        var folders: [VFSPath]
        var bytes: Int64
    }

    public func run(_ context: OperationContext) async throws {
        let filter: NameFilter? = try Self.filter(options.mask)
        let dst = try registry.writableProvider(for: target.location)
        context.progress(nil, "Reading archives")
        let errors = ItemErrorPolicy(context: context, action: "unpack")
        var plans: [Plan] = []
        var remembered: FolderExistsChoice?
        var failedArchives = 0
        for (n, archive) in archives.enumerated() {
            try await context.checkpoint()
            do {
                guard let plan = try await plan(archive, filter: filter, dst: dst, more: n < archives.count - 1,
                                                remembered: &remembered, context: context) else { continue }
                plans.append(plan)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.log("\(archive.name): \(error.localizedDescription)")
                failedArchives += 1
            }
        }

        let total = plans.reduce(0) { $0 + $1.bytes }
        let files = plans.reduce(0) { $0 + $1.pairs.count }
        let monitor = QueueTransferMonitor(context: context, registry: registry, totalBytes: total, totalFiles: files,
                                           errors: errors)
        var pairsDone = 0
        let engine = SecureCopyEngine(registry: registry, options: options.copy, monitor: monitor)
        context.items(done: 0, total: archives.count)
        var done = 0
        for plan in plans {
            try await context.checkpoint()
            var complete = true
            for folder in plan.folders {
                guard try await errors.run(folder, { try await Self.makeFolders(folder, provider: dst) }) else {
                    complete = false
                    continue
                }
            }
            for (index, pair) in plan.pairs.enumerated() {
                defer {
                    pairsDone += 1
                    monitor.settle(bytes: 0, files: pairsDone)
                }
                try await context.checkpoint()
                monitor.setLabel("\(plan.archive.name), \(index + 1) of \(plan.pairs.count), \(pair.source.name)")
                var summary = TransferSummary()
                guard try await errors.run(pair.source, {
                    summary = try await engine.transfer(pair.source, to: pair.destination, mode: .copy)
                }) else {
                    complete = false
                    continue
                }
                for p in summary.skipped { context.log("Skipped \(p.path)") }
                if !summary.failed.isEmpty || !summary.skipped.isEmpty { complete = false }
            }
            context.log(complete ? "Unpacked \(plan.archive.name)" : "Unpacked \(plan.archive.name), not completely")
            if let mode = options.deleteAfter {
                if complete {
                    try await delete(plan.archive, mode: mode, errors: errors, context: context)
                } else {
                    context.log("Kept \(plan.archive.name): not everything in it was unpacked")
                }
            }
            if complete { done += 1 } else { failedArchives += 1 }
            context.items(done: done, total: archives.count)
        }
        context.progress(1, archives.count == 1 ? "Unpacked" : "\(done) of \(archives.count) archives unpacked")
        if failedArchives > 0 {
            throw UnpackProblem(failed: failedArchives, total: archives.count)
        }
    }

    public struct UnpackProblem: LocalizedError, Equatable {
        public let failed: Int
        public let total: Int
        public var errorDescription: String? {
            total == 1 ? "The archive was not unpacked completely"
                : "\(failed) of \(total) archives were not unpacked completely"
        }
    }

    static func filter(_ mask: String) throws -> NameFilter? {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" || trimmed == "*.*" { return nil }
        return try NameFilter(trimmed)
    }

    private func plan(_ archive: VFSPath, filter: NameFilter?, dst: any WritableProvider, more: Bool,
                      remembered: inout FolderExistsChoice?, context: OperationContext) async throws -> Plan? {
        let item = try await registry.provider(for: archive.location).item(at: archive)
        guard let root = try await registry.openContainer(item, byContent: true) else {
            throw VFSError.unsupported("unpacking \(archive.name): it is not an archive Basil can read")
        }
        let provider = try registry.provider(for: root.location)
        guard provider.capabilities.contains(.read) else {
            throw VFSError.unsupported("unpacking \(archive.name): it holds no file contents (it is a file list)")
        }

        // What gets unpacked, as paths relative to the folder it lands in.
        var entries: [(source: VFSPath, relative: [String], size: Int64)] = []
        var topFolders = Set<String>()
        let whole = filter == nil && options.paths
        if whole {
            for try await batch in provider.list(root) {
                for child in batch where child.name != Self.junkFolder {
                    let isFolder = child.kind == .directory
                    if isFolder { topFolders.insert(child.name) }
                    let size = isFolder ? try await TransferOperation.size(of: child.path, registry, context) : (child.size ?? 0)
                    entries.append((child.path, [child.name], size))
                }
            }
        } else {
            try await collect(root, relative: [], provider: provider, filter: filter, into: &entries, context: context)
            if options.paths {
                for e in entries where e.relative.count > 1 { topFolders.insert(e.relative[0]) }
            } else {
                // Flat: one file per name; a later file with a name already used is left out.
                var used = Set<String>()
                var flat: [(source: VFSPath, relative: [String], size: Int64)] = []
                for e in entries {
                    let name = e.relative[e.relative.count - 1]
                    if used.insert(name.lowercased()).inserted {
                        flat.append((e.source, [name], e.size))
                    } else {
                        context.log("Left out \(e.source.path): another file named \(name) is unpacked already")
                    }
                }
                entries = flat
            }
        }
        guard !entries.isEmpty else {
            context.log("\(archive.name): nothing to unpack" + (filter != nil ? " matches \(options.mask)" : ""))
            return nil
        }

        let top = Set(entries.map { $0.relative[0] }).filter { $0 != Self.junkFile }
        let single = top.count == 1 ? top.first : nil
        let wraps = options.ownFolder && top.count > 1
        var base = target
        var folders: [VFSPath] = []
        var renamedTop: (from: String, to: String)?
        // The folder this archive makes: its own folder, or its single top folder.
        let made: VFSPath? = wraps ? target.appending(Self.folderName(for: archive.name))
            : single.flatMap { topFolders.contains($0) ? target.appending($0) : nil }
        if var folder = made {
            if let existing = try? await dst.fingerprint(of: folder) {
                let free = try await Self.freeName(folder, provider: dst)
                let choice: FolderExistsChoice
                if existing.kind != .directory {
                    context.log("\(folder.name) exists and is not a folder: unpacking into \(free)")
                    choice = .newName
                } else if let remembered {
                    choice = remembered
                } else {
                    guard case .folderExists(let answer, let forAll) = await context.ask(.folderExists(
                        FolderExists(folder: folder, archive: archive, newName: free, moreArchives: more)))
                    else { throw CancellationError() }
                    if forAll { remembered = answer }
                    choice = answer
                }
                switch choice {
                case .merge:
                    context.log("Unpacking \(archive.name) into the existing folder \(folder.path)")
                case .newName:
                    if !wraps { renamedTop = (folder.name, free) }
                    folder = target.appending(free)
                case .skip:
                    context.log("Skipped \(archive.name): \(folder.name) already exists")
                    return nil
                case .cancel:
                    throw CancellationError()
                }
            }
            if wraps {
                base = folder
                folders.append(folder)
            } else if let renamedTop {
                // The single top folder lands under the new name.
                entries = entries.map { e in
                    var r = e.relative
                    if r.first == renamedTop.from { r[0] = renamedTop.to }
                    return (e.source, r, e.size)
                }
            }
        }

        var pairs: [(VFSPath, VFSPath)] = []
        for e in entries {
            let destination = e.relative.reduce(base) { $0.appending($1) }
            if !whole, let parent = destination.parent, parent != base, !folders.contains(parent) { folders.append(parent) }
            pairs.append((e.source, destination))
        }
        if !folders.contains(base), base == target { folders.insert(target, at: 0) }
        return Plan(archive: archive, pairs: pairs, folders: folders, bytes: entries.reduce(0) { $0 + $1.size })
    }

    /// Every file and link below `folder` whose name matches the filter (all without one).
    private func collect(_ folder: VFSPath, relative: [String], provider: any FileSystemProvider, filter: NameFilter?,
                         into entries: inout [(source: VFSPath, relative: [String], size: Int64)],
                         context: OperationContext) async throws {
        var children: [FileItem] = []
        for try await batch in provider.list(folder) { children += batch }
        for child in children {
            try await context.checkpoint()
            switch child.kind {
            case .directory:
                if relative.isEmpty, child.name == Self.junkFolder { continue }
                try await collect(child.path, relative: relative + [child.name], provider: provider, filter: filter,
                                  into: &entries, context: context)
            case .file, .symlink:
                if let filter, !filter.matches(child.name) { continue }
                entries.append((child.path, relative + [child.name], child.size ?? 0))
            case .other:
                continue
            }
        }
    }

    /// Creates `folder` and the folders above it that are missing.
    static func makeFolders(_ folder: VFSPath, provider: any WritableProvider) async throws {
        if let fp = try? await provider.fingerprint(of: folder) {
            guard fp.kind == .directory else { throw VFSError.notADirectory(folder) }
            return
        }
        if let parent = folder.parent { try await makeFolders(parent, provider: provider) }
        do {
            try await provider.makeDirectory(folder)
        } catch VFSError.alreadyExists {
            return
        }
    }

    /// "photos (2)", "photos (3)", ... the first name that is free.
    static func freeName(_ folder: VFSPath, provider: any WritableProvider) async throws -> String {
        guard let parent = folder.parent else { return folder.name }
        for n in 2... {
            let candidate = "\(folder.name) (\(n))"
            if (try? await provider.fingerprint(of: parent.appending(candidate))) == nil { return candidate }
        }
        return folder.name
    }

    private func delete(_ archive: VFSPath, mode: DeleteMode, errors: ItemErrorPolicy, context: OperationContext) async throws {
        guard archive.location.container == nil else {
            return context.log("Kept \(archive.name): it is inside another archive")
        }
        let volumes = await registry.containerOpener(forFile: archive)?.volumes(of: archive, registry: registry) ?? [archive]
        for volume in volumes {
            let removed: Bool
            switch mode {
            case .trash:
                removed = try await errors.run(volume) { try await registry.writableProvider(for: volume.location).trash(volume) }
            case .permanently:
                removed = try await DeleteOperation.removeTree(volume, registry, errors, context)
            }
            if removed { context.log(mode == .trash ? "Moved \(volume.name) to the Trash" : "Deleted \(volume.name)") }
        }
    }
}
