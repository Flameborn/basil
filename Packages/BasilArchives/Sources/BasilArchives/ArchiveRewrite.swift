import BasilCore
import BasilVFS
import CArchive
import Darwin
import Dispatch
import Foundation
import Synchronization

/// How deletes, renames and adds change the paths of entries kept from an existing archive.
struct ChangePlan: Sendable {
    let deletes: [String]
    let renames: [(from: String, to: String)]
    /// Paths written by adds; an old entry with one of these paths is replaced.
    let added: Set<String>

    init(_ changes: [ContainerChange]) {
        var deletes: [String] = [], renames: [(String, String)] = [], added = Set<String>()
        for change in changes {
            switch change {
            case .delete(let p): deletes.append(p)
            case .rename(let from, let to): renames.append((from, to))
            default: if let p = change.addedPath { added.insert(p) }
            }
        }
        self.deletes = deletes
        self.renames = renames
        self.added = added
    }

    /// The new path of an old entry, or nil when it is deleted or replaced.
    func map(_ old: String) -> String? {
        var path = old
        for d in deletes where path == d || path.hasPrefix(d + "/") { return nil }
        for r in renames where path == r.from || path.hasPrefix(r.from + "/") {
            path = r.to + path.dropFirst(r.from.count)
            break
        }
        return added.contains(path) ? nil : path
    }
}

/// Writes one new archive file: the kept entries of `base` (with deletes and renames applied),
/// then the added items read through their providers. The libarchive handles live on `queue`.
final class ArchiveRewrite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "basil.archive.write", qos: .userInitiated)
    let output: URL
    let spec: LibArchiveFormats.Spec
    let base: URL?
    /// The entry name for a single compressed file.
    let rawName: String
    /// Only touched on `queue`.
    private var writer: LibArchiveWriter?
    /// Expected files in the result, path -> size (nil when the size could not be known).
    private(set) var expected: [String: Int64?] = [:]

    init(output: URL, spec: LibArchiveFormats.Spec, base: URL?, rawName: String) {
        self.output = output
        self.spec = spec
        self.base = base
        self.rawName = rawName
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                UTF8Locale.use() // per thread: a serial queue does not always run on the same one
                continuation.resume(with: Result { try body() })
            }
        }
    }

    func write(_ changes: [ContainerChange], macMetadata: Bool, registry: ProviderRegistry,
               monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        var result = ContainerWriteResult()
        let plan = ChangePlan(changes)
        try await run { [self] in writer = try LibArchiveWriter(url: output, spec: spec) }
        do {
            if base != nil {
                let warnings = try await copyBase(plan, monitor: monitor)
                result.warnings += warnings
            }
            let adds = changes.filter { $0.addedPath != nil }
            if spec.container == .raw, adds.count != 1 || adds.contains(where: { if case .addFile = $0 { false } else { true } }) {
                throw ArchiveError.damaged("A single compressed file holds exactly one file", archive: output.lastPathComponent)
            }
            for change in adds {
                try await monitor.checkpoint()
                try await add(change, macMetadata: macMetadata && spec.storesMacMetadata, registry: registry,
                              monitor: monitor, result: &result)
            }
            try await run { [self] in
                try writer?.close()
                writer = nil
            }
        } catch {
            try? await run { [self] in writer = nil }
            throw error
        }
        result.entries = expected.count
        return result
    }

    // MARK: Kept entries

    private func copyBase(_ plan: ChangePlan, monitor: any ContainerWriteMonitor) async throws -> [String] {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await run { [self] in
                try copyBaseBlocking(plan, isCancelled: { cancelled.withLock { $0 } }, written: monitor.written)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private func copyBaseBlocking(_ plan: ChangePlan, isCancelled: () -> Bool, written: (Int64) -> Void) throws -> [String] {
        guard let base, let writer, let reader = try LibArchiveReader(url: base, raw: false) else {
            throw ArchiveError.damaged("The archive can no longer be read", archive: base?.lastPathComponent ?? "")
        }
        var warnings: [String] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var reported: Int64 = 0
        while let header = try reader.nextHeader() {
            if isCancelled() { throw CancellationError() }
            guard header.path != "/", let newPath = plan.map(header.path), let entry = reader.currentEntry else { continue }
            if header.isEncrypted {
                throw ArchiveError.damaged("\(header.path.dropFirst()) is encrypted and cannot be copied into the new archive without its password",
                                           archive: base.lastPathComponent)
            }
            if let link = header.hardlink {
                guard let mapped = plan.map(link) else {
                    warnings.append("Left out \(newPath.dropFirst()): it was a hard link to a removed entry")
                    continue
                }
                archive_entry_set_hardlink_utf8(entry, String(mapped.dropFirst()))
            }
            archive_entry_set_pathname_utf8(entry, String(newPath.dropFirst()))
            try writer.writeHeader(entry)
            let isFile = header.type == 0o100000 && header.hardlink == nil
            if isFile {
                var copied: Int64 = 0
                while true {
                    let n = try reader.readData(into: &buffer)
                    if n == 0 { break }
                    try buffer.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
                    copied += Int64(n)
                    if isCancelled() { throw CancellationError() }
                }
                expected[newPath] = .some(copied)
            } else if header.type == 0o100000 {
                expected[newPath] = .some(nil)
            }
            try writer.finishEntry()
            if spec.isZip, let mac = header.macMetadata {
                try writer.writeZipAppleDouble(mac, for: newPath, modified: header.modified)
            }
            let bytes = reader.compressedBytesRead
            written(bytes - reported)
            reported = bytes
        }
        return warnings
    }

    // MARK: Added items

    private func add(_ change: ContainerChange, macMetadata: Bool, registry: ProviderRegistry,
                     monitor: any ContainerWriteMonitor, result: inout ContainerWriteResult) async throws {
        guard let at = change.addedPath else { return }
        let name = spec.container == .raw ? rawName : String(at.dropFirst())
        switch change {
        case .addDirectory(let source, _):
            var metadata: FileMetadata?
            if let source { metadata = try await registry.writableProvider(for: source.location).metadata(of: source) }
            let folderMetadata = metadata
            try await run { [self] in
                let entry = Self.entry(name, type: 0o040000, size: 0, metadata: folderMetadata, defaultPerm: 0o755)
                defer { archive_entry_free(entry) }
                try writer?.writeHeader(entry)
                try writer?.finishEntry()
            }
        case .addSymlink(let source, _):
            let provider = try registry.writableProvider(for: source.location)
            let target = try await provider.readSymlink(source)
            let metadata = try await provider.metadata(of: source)
            try await run { [self] in
                let entry = Self.entry(name, type: 0o120000, size: 0, metadata: metadata, defaultPerm: 0o755)
                defer { archive_entry_free(entry) }
                archive_entry_set_symlink_utf8(entry, target)
                try writer?.writeHeader(entry)
                try writer?.finishEntry()
            }
        case .addFile(let source, _):
            try await addFile(source, at: at, name: name, macMetadata: macMetadata, registry: registry,
                              monitor: monitor, result: &result)
        default:
            break
        }
    }

    private func addFile(_ source: VFSPath, at: String, name: String, macMetadata: Bool, registry: ProviderRegistry,
                         monitor: any ContainerWriteMonitor, result: inout ContainerWriteResult) async throws {
        let provider = try registry.writableProvider(for: source.location)
        var opened: (FileFingerprint, FileMetadata, any ReadableFile)?
        while opened == nil {
            do {
                let fp = try await provider.fingerprint(of: source)
                let metadata = try await provider.metadata(of: source)
                opened = (fp, metadata, try await provider.openForReading(source, bypassCache: false))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if try await monitor.skipAfterError(error, at: source) {
                    result.skipped.append(source)
                    monitor.log("Skipped \(source.path)")
                    return
                }
            }
        }
        guard let (before, metadata, reader) = opened else { return }
        defer { Task { await reader.close() } }
        let appleDouble = macMetadata ? AppleDouble.pack(metadata.extendedAttributes) : nil
        let size = before.size
        let isZip = spec.isZip
        try await run { [self] in
            let entry = Self.entry(name, type: 0o100000, size: size, metadata: metadata, defaultPerm: 0o644)
            defer { archive_entry_free(entry) }
            if let appleDouble, !isZip {
                appleDouble.withUnsafeBytes { archive_entry_copy_mac_metadata(entry, $0.baseAddress, $0.count) }
            }
            try writer?.writeHeader(entry)
        }
        var offset: Int64 = 0
        let chunk = 1 << 20
        while offset < size {
            try await monitor.checkpoint()
            let data = try await reader.read(at: offset, count: Int(min(Int64(chunk), size - offset)))
            if data.isEmpty { break }
            try await run { [self] in try data.withUnsafeBytes { try writer?.write($0) } }
            offset += Int64(data.count)
            monitor.written(bytes: Int64(data.count))
        }
        try await run { [self] in
            try writer?.finishEntry()
            if let appleDouble, isZip {
                try writer?.writeZipAppleDouble(appleDouble, for: at, modified: metadata.modified)
            }
        }
        let after = try? await provider.fingerprint(of: source)
        if after != before || offset != size {
            result.changedSources.append(source)
            monitor.log("\(source.name) changed while it was packed")
            expected[at] = .some(nil)
        } else {
            expected[at] = .some(size)
        }
    }

    private static func entry(_ name: String, type: UInt32, size: Int64, metadata: FileMetadata?, defaultPerm: UInt16) -> OpaquePointer {
        let entry = archive_entry_new()!
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, type)
        archive_entry_set_perm(entry, mode_t(metadata?.permissions ?? defaultPerm))
        archive_entry_set_size(entry, la_int64_t(size))
        let now = timespec(tv_sec: time(nil), tv_nsec: 0)
        let modified = metadata?.modified ?? now
        archive_entry_set_mtime(entry, modified.tv_sec, modified.tv_nsec)
        if let created = metadata?.created { archive_entry_set_birthtime(entry, created.tv_sec, created.tv_nsec) }
        return entry
    }

    // MARK: After writing

    /// F_FULLFSYNC, so the new archive is on disk before it replaces anything.
    func synchronize() async throws {
        try await run { [self] in
            let fd = open(output.path, O_RDONLY)
            guard fd >= 0 else { throw VFSError.posix(code: errno, path: .local(output.path)) }
            defer { close(fd) }
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw VFSError.posix(code: errno, path: .local(output.path)) }
        }
    }

    /// Reads the new archive back: every entry's data must read without errors, and every file
    /// written must be there with its size.
    func verify(backend: LibArchiveBackend) async throws {
        let expected = expected
        let output = output
        let isRaw = spec.container == .raw
        let displayName = rawName
        try await run {
            let problems = try backend.test(output, byContent: true) { _, _ in true }
            if let first = problems.first {
                throw ArchiveError.damaged("The new archive did not read back correctly (\(first))", archive: displayName)
            }
            let entries = try backend.entries(of: output, byContent: true) ?? []
            if isRaw {
                guard entries.count == 1 else {
                    throw ArchiveError.damaged("The new archive did not read back correctly", archive: displayName)
                }
                return
            }
            let found = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
            for (path, size) in expected {
                guard let entry = found[path] else {
                    throw ArchiveError.damaged("\(path.dropFirst()) is missing from the new archive", archive: displayName)
                }
                if let size, let actual = entry.size, actual != size {
                    throw ArchiveError.damaged("\(path.dropFirst()) has the wrong size in the new archive", archive: displayName)
                }
            }
        }
    }
}
