import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization

/// Creates and changes 7z archives, and creates encrypted zip files, with 7zz. Like the
/// libarchive writer it is all or nothing: the new archive is written next to the target as
/// ".basil-partial-*" (changes to an existing one use 7zz's "-u-" + "-u...!new" switches, so the
/// original is only read), F_FULLFSYNCed, tested and listed, and only then renamed into place.
///
/// 7zz reads the files itself, by name relative to a working folder. When every add is a local
/// file at the same relative path as in the archive (packing items of one folder, the usual
/// case), 7zz runs in that folder with a list of the top-level names, and everything on disk
/// under them that is not to be added is excluded. Otherwise the adds are put together in a
/// staging folder first (clones on the same volume, copies otherwise).
struct SevenZipWriter: Sendable {
    let tool: SevenZipTool

    static let sevenZipFormat = PackFormat(id: "7z", name: "7z", levels: [.store, .fast, .normal, .maximum, .ultra],
                                           solid: true, encryption: true, nameEncryption: true)

    /// Whether this writer creates `options` (7z, and zip with a password).
    static func creates(_ options: PackOptions) -> Bool {
        options.format == "7z" || (options.format == "zip" && options.encryptionPassword != nil)
    }

    static func formatArguments(_ options: PackOptions) -> [String] {
        let password = options.encryptionPassword != nil
        if options.format == "zip" {
            let level = [PackLevel.store: 0, .fast: 1, .normal: 5, .maximum: 9, .ultra: 9][options.level] ?? 5
            return ["-tzip", "-mx=\(level)"] + (password ? ["-p", "-mem=AES256"] : [])
        }
        let level = [PackLevel.store: 0, .fast: 1, .normal: 5, .maximum: 7, .ultra: 9][options.level] ?? 5
        return ["-t7z", "-mx=\(level)", "-ms=\(options.solid ? "on" : "off")"]
            + (password ? ["-p"] + (options.encryptNames ? ["-mhe=on"] : []) : [])
    }

    private var backend: SevenZipBackend { SevenZipBackend(tool: tool) }

    // MARK: Create

    func create(_ destination: VFSPath, options: PackOptions, changes: [ContainerChange], replacing: Bool,
                registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        guard destination.location == .local, let folder = destination.parent else {
            throw VFSError.unsupported("creating archives outside local folders")
        }
        let target = URL(fileURLWithPath: destination.path)
        if !replacing, FileManager.default.fileExists(atPath: target.path) { throw VFSError.alreadyExists(destination) }
        let partial = URL(fileURLWithPath: folder.appending(ArchiveOpener.partialName(destination.name)).path)
        let password = options.encryptionPassword
        do {
            var result = try await add(changes, base: nil, output: partial, format: Self.formatArguments(options),
                                       password: password, passwordLines: 1, registry: registry, monitor: monitor)
            let skipped = Set(result.skipped)
            let expected = Set(changes.compactMap { change -> String? in
                guard let at = change.addedPath, !(change.source.map(skipped.contains) ?? false) else { return nil }
                return at
            })
            result.changedSources += try await verify(partial, zip: options.format == "zip", password: password,
                                                      expected: expected, sizes: result.sizes, sources: result.sources)
            try finish(partial, into: target, replacing: replacing, path: destination)
            return result.result
        } catch {
            unlink(partial.path)
            throw error
        }
    }

    // MARK: Update

    func update(_ container: VFSPath, provider: ArchiveProvider, changes: [ContainerChange],
                registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        guard container.location == .local, let folder = container.parent else {
            throw VFSError.unsupported("Archives inside archives cannot be changed yet.")
        }
        let url = URL(fileURLWithPath: container.path)
        let before = ArchiveProvider.stamp(url)
        let password: String? = provider.hasEncryptedEntries || provider.namesEncrypted ? try await provider.knownPassword() : nil
        // 7zz asks twice when it changes an encrypted archive: to open it, and for the new items.
        let lines = 2
        let entries = provider.explicitEntries
        var expected = Set(entries.map(\.path))
        var temporaries: [URL] = []
        defer { temporaries.forEach { unlink($0.path) } }
        func next() -> URL {
            let u = URL(fileURLWithPath: folder.appending(ArchiveOpener.partialName(container.name)).path)
            temporaries.append(u)
            return u
        }
        var current = url

        // Deletes and renames first, on the entries as stored (an implied folder has none: its entries go).
        var deleted: [String] = []
        var renames: [(String, String)] = []
        for change in changes {
            switch change {
            case .delete(let path):
                let below = entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
                deleted += below.compactMap(\.storedName)
                expected = expected.filter { $0 != path && !$0.hasPrefix(path + "/") }
            case .rename(let from, let to):
                for entry in entries where entry.path == from || entry.path.hasPrefix(from + "/") {
                    guard let stored = entry.storedName else { continue }
                    renames.append((stored, String((to + entry.path.dropFirst(from.count)).dropFirst())))
                }
                expected = Set(expected.map { $0 == from || $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 })
            default:
                break
            }
        }
        if !deleted.isEmpty {
            try await monitor.checkpoint()
            let list = try ListFile(deleted)
            defer { list.remove() }
            let output = next()
            let run = try tool.run(["d", "-bso1", "-bsp0", "-spd", "-y", "-i@" + list.path, "-u-", "-up1!" + output.path,
                                    "--", current.path], password: password, passwordLines: lines)
            try check(run, archive: container.name)
            current = output
        }
        if !renames.isEmpty {
            try await monitor.checkpoint()
            let output = next()
            let run = try tool.run(["rn", "-bso1", "-bsp0", "-spd", "-y", "-u-", "-up1!" + output.path, "--", current.path]
                                    + renames.flatMap { [$0.0, $0.1] }, password: password, passwordLines: lines)
            try check(run, archive: container.name)
            current = output
        }
        var result = Written()
        let adds = changes.filter { $0.addedPath != nil }
        if !adds.isEmpty {
            let output = next()
            var format = ["-t7z"]
            if password != nil { format += ["-p"] + (provider.namesEncrypted ? ["-mhe=on"] : []) }
            result = try await add(adds, base: current, output: output, format: format, password: password,
                                   passwordLines: lines, registry: registry, monitor: monitor)
            current = output
        }
        guard current != url else { return result.result } // nothing to change
        for change in adds { if let at = change.addedPath { expected.insert(at) } }
        for source in result.skipped {
            if let at = adds.first(where: { $0.source == source })?.addedPath { expected.remove(at) }
        }
        result.changedSources += try await verify(current, zip: false, password: password, expected: expected,
                                                  sizes: result.sizes, sources: result.sources)
        guard ArchiveProvider.stamp(url) == before else {
            throw ArchiveError.damaged("The archive changed while it was being updated. Nothing was changed; try again.",
                                       archive: container.name)
        }
        var st = Darwin.stat()
        if stat(url.path, &st) == 0 { chmod(current.path, st.st_mode & 0o7777) }
        try finish(current, into: url, replacing: true, path: container)
        return result.result
    }

    // MARK: Adding

    /// What an add run did, beyond the result: the size each file had when it was read, and its source.
    struct Written {
        var result = ContainerWriteResult()
        var sizes: [String: Int64] = [:]
        var sources: [String: VFSPath] = [:]
        var skipped: [VFSPath] { result.skipped }
        var changedSources: [VFSPath] {
            get { result.changedSources }
            set { result.changedSources = newValue }
        }
    }

    /// Runs `7zz a` for the adds in `changes`: into a new archive `output` (base nil), or as a
    /// changed copy of `base` written to `output`.
    private func add(_ changes: [ContainerChange], base: URL?, output: URL, format: [String], password: String?,
                     passwordLines: Int, registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> Written {
        var written = Written()
        var adds = changes.filter { $0.addedPath != nil }
        // Sources that cannot be read are asked about first (Retry / Skip), as 7zz only warns.
        var readable: [ContainerChange] = []
        for change in adds {
            guard case .addFile(let source, let at) = change else { readable.append(change); continue }
            while true {
                do {
                    let fingerprint = try await registry.writableProvider(for: source.location).fingerprint(of: source)
                    if source.location == .local {
                        let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
                        guard fd >= 0 else { throw VFSError.posix(code: errno, path: source) }
                        close(fd)
                    }
                    written.sizes[at] = fingerprint.size
                    written.sources[at] = source
                    readable.append(change)
                    break
                } catch {
                    if try await monitor.skipAfterError(error, at: source) {
                        written.result.skipped.append(source)
                        break
                    }
                }
            }
        }
        adds = readable
        guard !adds.isEmpty else {
            if base == nil { throw VFSError.unsupported("an archive with nothing in it") }
            return written
        }
        let before = try await fingerprints(of: adds, registry: registry)
        let total = written.sizes.values.reduce(0, +)
        let folder = output.deletingLastPathComponent()

        let names: [String]
        let exclusions: [String]
        let directory: URL
        var stage: URL?
        defer { if let stage { try? FileManager.default.removeItem(at: stage) } }
        if let plan = FastPlan(adds) {
            directory = plan.base
            names = plan.top
            exclusions = plan.exclusions()
        } else {
            let staging = folder.appendingPathComponent(ArchiveOpener.partialName("stage"), isDirectory: true)
            stage = staging
            try await self.stage(adds, in: staging, registry: registry, monitor: monitor)
            directory = staging
            names = FastPlan.topLevel(adds)
            exclusions = []
        }
        let list = try ListFile(names)
        defer { list.remove() }
        let excluded = try exclusions.isEmpty ? nil : ListFile(exclusions)
        defer { excluded?.remove() }
        var args = ["a", "-bso1", "-bsp1", "-spd", "-snl", "-y"] + format + ["-i@" + list.path]
        if let excluded { args.append("-x@" + excluded.path) }
        if let base {
            args += ["-u-", "-up1q1r2x2y2z2w2!" + output.path, "--", base.path]
        } else {
            args += ["--", output.path]
        }
        let run = try await runWithProgress(args, in: directory, password: password, passwordLines: passwordLines,
                                            totalBytes: total, monitor: monitor)
        if run.status == 1 {
            for warning in run.errors { monitor.log("7-Zip: \(warning)") }
        } else {
            try check(run, archive: output.lastPathComponent)
        }
        // A source that changed while 7zz read it: its entry may not match it.
        let after = try await fingerprints(of: adds, registry: registry)
        for (source, fingerprint) in before where after[source] != fingerprint {
            written.result.changedSources.append(source)
        }
        written.result.entries = adds.count
        return written
    }

    private func fingerprints(of adds: [ContainerChange], registry: ProviderRegistry) async throws -> [VFSPath: FileFingerprint] {
        var result: [VFSPath: FileFingerprint] = [:]
        for change in adds {
            guard case .addFile(let source, _) = change else { continue }
            result[source] = try? await registry.writableProvider(for: source.location).fingerprint(of: source)
        }
        return result
    }

    /// Puts the adds together in `staging` at their archive paths: folders made, links made,
    /// files cloned (same volume) or copied through their provider, with dates and permissions.
    private func stage(_ adds: [ContainerChange], in staging: URL, registry: ProviderRegistry,
                       monitor: any ContainerWriteMonitor) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var folderDates: [(String, timespec)] = []
        for change in adds {
            try await monitor.checkpoint()
            guard let at = change.addedPath else { continue }
            let destination = staging.path + at
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            switch change {
            case .addDirectory(let source, _):
                try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
                if let source, let metadata = try? await registry.writableProvider(for: source.location).metadata(of: source) {
                    if let permissions = metadata.permissions { chmod(destination, mode_t(permissions)) }
                    if let modified = metadata.modified { folderDates.append((destination, modified)) }
                }
            case .addSymlink(let source, _):
                let target = try await registry.writableProvider(for: source.location).readSymlink(source)
                guard symlink(target, destination) == 0 else { throw VFSError.posix(code: errno, path: .local(destination)) }
            case .addFile(let source, _):
                if source.location == .local, clonefile(source.path, destination, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 {
                    continue
                }
                try await copy(source, to: destination, registry: registry, monitor: monitor)
            default:
                break
            }
        }
        // Folder dates last: adding their content changed them.
        for (path, modified) in folderDates.reversed() {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
            utimensat(AT_FDCWD, path, &times, 0)
        }
    }

    private func copy(_ source: VFSPath, to destination: String, registry: ProviderRegistry,
                      monitor: any ContainerWriteMonitor) async throws {
        let provider = try registry.writableProvider(for: source.location)
        let reader = try await provider.openForReading(source, bypassCache: false)
        guard FileManager.default.createFile(atPath: destination, contents: nil),
              let handle = FileHandle(forWritingAtPath: destination) else {
            await reader.close()
            throw VFSError.permissionDenied(.local(destination))
        }
        do {
            var offset: Int64 = 0
            while true {
                try await monitor.checkpoint()
                let chunk = try await reader.read(at: offset, count: 1 << 20)
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
            }
            try handle.close()
            await reader.close()
        } catch {
            try? handle.close()
            await reader.close()
            throw error
        }
        if let metadata = try? await provider.metadata(of: source) {
            if let permissions = metadata.permissions { chmod(destination, mode_t(permissions)) }
            if let modified = metadata.modified {
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
                utimensat(AT_FDCWD, destination, &times, 0)
            }
        }
    }

    /// Runs 7zz while reporting its progress as bytes, checking for pause and cancel; a cancel
    /// stops 7zz.
    private func runWithProgress(_ args: [String], in directory: URL, password: String?, passwordLines: Int,
                                 totalBytes: Int64, monitor: any ContainerWriteMonitor) async throws -> SevenZipTool.Output {
        let running = try tool.start(args, password: password, passwordLines: passwordLines, in: directory)
        let stderr = running.drainStderr()
        let state = Mutex<(fraction: Double, done: Bool, output: String)>((0, false, ""))
        let fd = running.stdout
        SevenZipTool.thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                pending += text
                let pieces = pending.split(omittingEmptySubsequences: false) { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" }
                pending = String(pieces.last ?? "")
                let fraction = pieces.dropLast().compactMap { SevenZipBackend.progress($0)?.0 }.last
                state.withLock { s in
                    s.output += text
                    if let fraction { s.fraction = fraction }
                }
            }
            state.withLock { $0.done = true }
        }
        var reported: Int64 = 0
        do {
            while true {
                try await monitor.checkpoint()
                let (fraction, done) = state.withLock { ($0.fraction, $0.done) }
                let bytes = Int64(Double(totalBytes) * fraction)
                if bytes > reported {
                    monitor.written(bytes: bytes - reported)
                    reported = bytes
                }
                if done { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            running.stop()
            throw error
        }
        if totalBytes > reported { monitor.written(bytes: totalBytes - reported) }
        let status = running.wait()
        return SevenZipTool.Output(status: status, stdout: Data(state.withLock { $0.output }.utf8), stderr: stderr.wait())
    }

    private func check(_ run: SevenZipTool.Output, archive: String) throws {
        guard run.status != 0 else { return }
        if run.stderr.contains("Wrong password") { throw ArchiveError.wrongPassword(archive: archive) }
        throw ArchiveError.damaged(run.errors.first ?? "7-Zip stopped with exit status \(run.status)", archive: archive)
    }

    // MARK: Checking

    /// Tests the new archive and compares its entries with what should be in it. Returns the
    /// sources whose entries do not match them (they changed while 7zz read them).
    private func verify(_ url: URL, zip: Bool, password: String?, expected: Set<String>, sizes: [String: Int64],
                        sources: [String: VFSPath]) async throws -> [VFSPath] {
        let backend = zip ? backend.zipFallback() : backend
        let (entries, problems) = try await ArchiveOpener.blocking { () -> ([ArchiveEntry], [String]) in
            let entries = try backend.entries(of: url, byContent: true, password: password) ?? []
            let problems = try backend.test(url, byContent: true, password: password) { _, _ in true }
            return (entries, problems)
        }
        if let problem = problems.first {
            throw ArchiveError.damaged("The new archive failed its test (\(problem)). Nothing was changed.",
                                       archive: url.lastPathComponent)
        }
        var changed: [VFSPath] = []
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        for path in expected where byPath[path] == nil {
            // A source deleted while it was packed is a changed source; anything else is an error.
            if let source = sources[path] {
                changed.append(source)
                continue
            }
            if expected.contains(where: { $0.hasPrefix(path + "/") }) { continue } // a folder entry 7zz did not store
            throw ArchiveError.damaged("The new archive is missing \(path.dropFirst()). Nothing was changed.",
                                       archive: url.lastPathComponent)
        }
        for (path, size) in sizes {
            if let entry = byPath[path], entry.kind == .file, entry.size != size, let source = sources[path] {
                changed.append(source)
            }
        }
        return changed
    }

    private func finish(_ partial: URL, into target: URL, replacing: Bool, path: VFSPath) throws {
        let fd = open(partial.path, O_RDONLY)
        guard fd >= 0 else { throw VFSError.posix(code: errno, path: .local(partial.path)) }
        let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        close(fd)
        guard synced else { throw VFSError.posix(code: errno, path: .local(partial.path)) }
        let r = replacing ? rename(partial.path, target.path)
                          : renamex_np(partial.path, target.path, UInt32(RENAME_EXCL))
        if r != 0 {
            if errno == EEXIST { throw VFSError.alreadyExists(path) }
            throw VFSError.posix(code: errno, path: path)
        }
    }
}

/// The adds of one local folder at the same relative paths as in the archive: 7zz can read them
/// in place, given the top-level names, with everything else under them excluded.
struct FastPlan {
    let base: URL
    let top: [String]
    /// Archive paths of every add ("/folder/file.txt").
    let all: Set<String>

    init?(_ adds: [ContainerChange]) {
        guard let first = adds.first, let at = first.addedPath, let source = first.source,
              source.location == .local, source.path.hasSuffix(at) else { return nil }
        let base = String(source.path.dropLast(at.count))
        for change in adds {
            guard let at = change.addedPath, let source = change.source, source.location == .local,
                  source.path == base + at else { return nil }
        }
        self.base = URL(fileURLWithPath: base.isEmpty ? "/" : base, isDirectory: true)
        self.top = Self.topLevel(adds)
        self.all = Set(adds.compactMap(\.addedPath))
    }

    /// Relative names of the adds whose folder is not itself added (7zz takes folders whole).
    static func topLevel(_ adds: [ContainerChange]) -> [String] {
        var folders = Set<String>()
        for change in adds { if case .addDirectory(_, let at) = change { folders.insert(at) } }
        return adds.compactMap { change -> String? in
            guard let at = change.addedPath, !folders.contains(ArchiveIndex.parent(of: at)) else { return nil }
            return String(at.dropFirst())
        }
    }

    /// Everything under the top-level folders that is not to be added, relative to `base`.
    func exclusions() -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        for name in top where all.contains("/" + name) {
            let folder = base.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
                  let walker = fm.enumerator(atPath: folder.path) else { continue }
            while let relative = walker.nextObject() as? String {
                let path = "/" + name + "/" + relative
                if !all.contains(path) {
                    result.append(String(path.dropFirst()))
                    walker.skipDescendants()
                }
            }
        }
        return result
    }
}

/// A temporary list file for 7zz's @ and -i@ / -x@ switches, one name per line in UTF-8.
struct ListFile {
    let url: URL
    var path: String { url.path }

    init(_ names: [String]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-7z-\(UUID().uuidString).txt")
        try Data(names.joined(separator: "\n").utf8).write(to: url)
    }

    func remove() { unlink(url.path) }
}
