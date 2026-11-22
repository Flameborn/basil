import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization

extension ProviderID {
    public static let fileList = ProviderID("filelist")
}

/// Why nothing but browsing works in a file list.
func fileListRefusal(_ name: String) -> String {
    "\(name) is a file list: it holds names, sizes and dates, not the files, so it cannot be changed or copied from."
}

/// A file list (.lst, see `FileListFormat`) shown as a folder tree. It has names, sizes and
/// dates only, so it has no `.read` capability: copying out of it, viewing, editing, and every
/// change throw `.unsupported`. Folder sizes (`totals(of:)`) work from the listed sizes.
public final class FileListProvider: WritableProvider, @unchecked Sendable {
    public let location: ProviderLocation
    public var capabilities: ProviderCapabilities { [] }

    private let url: URL?
    private let name: String
    private let state: Mutex<(index: FileListIndex, stamp: ArchiveProvider.Stamp?)>
    /// The folder the list was made of, as recorded in it.
    public let recordedRoot: String?

    init(location: ProviderLocation, url: URL?, parsed: FileListFormat.Parsed) {
        self.location = location
        self.url = url
        self.name = location.container?.name ?? "file list"
        self.recordedRoot = parsed.root
        self.state = Mutex((FileListIndex(parsed.entries), url.flatMap(ArchiveProvider.stamp)))
    }

    private var refusal: VFSError { .unsupported(fileListRefusal(name)) }

    /// The index, read again when the list file changed (F2 after the list was replaced).
    private func index() throws -> FileListIndex {
        let (index, stamp) = state.withLock { ($0.index, $0.stamp) }
        guard let url else { return index }
        let now = ArchiveProvider.stamp(url)
        guard now != stamp else { return index }
        guard now != nil else { throw VFSError.notFound(location.container ?? .local(url.path)) }
        guard let data = try? Data(contentsOf: url), let parsed = FileListFormat.parse(data) else { return index }
        let fresh = FileListIndex(parsed.entries)
        state.withLock { $0 = (fresh, now) }
        return fresh
    }

    private func entry(_ path: VFSPath) throws -> FileListEntry {
        guard path.location == location else { throw VFSError.noProvider(path.location) }
        guard let entry = try index().entry(path.path) else { throw VFSError.notFound(path) }
        return entry
    }

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            do {
                let index = try index()
                guard let folder = index.entry(directory.path) else { throw VFSError.notFound(directory) }
                guard folder.kind == .directory else { throw VFSError.notADirectory(directory) }
                let items = (index.children[directory.path] ?? []).compactMap { child -> FileItem? in
                    let path = directory.appending(child)
                    return index.entry(path.path).map { makeItem($0, path: path, index: index) }
                }
                continuation.yield(items)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        let entry = try entry(path)
        return makeItem(entry, path: path, index: try index())
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    private func makeItem(_ entry: FileListEntry, path: VFSPath, index: FileListIndex) -> FileItem {
        let kind: FileItem.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink(target: linkTarget(entry, index: index))
        case .other: .other
        }
        return FileItem(path: path, kind: kind, size: entry.kind == .directory ? nil : entry.size,
                        modified: entry.modified.map(Self.date), created: entry.created.map(Self.date),
                        permissions: entry.permissions, isHidden: path.name.hasPrefix("."))
    }

    private func linkTarget(_ entry: FileListEntry, index: FileListIndex) -> FileItem.Kind.Target {
        guard let target = entry.symlinkTarget, !target.hasPrefix("/") else { return .unknown }
        let resolved = VFSPath.local(ArchiveIndex.parent(of: entry.path) + "/" + target).path
        switch index.entry(resolved)?.kind {
        case .directory: return .directory
        case .file: return .file
        case nil: return .broken
        default: return .unknown
        }
    }

    static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    // MARK: WritableProvider: only the listed facts, no contents, no changes

    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let entry = try entry(path)
        let kind: FileFingerprint.Kind = switch entry.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other: .other
        }
        return FileFingerprint(kind: kind, size: entry.size ?? 0,
                               modifiedNanos: entry.modified.map { Int64($0.tv_sec) * 1_000_000_000 + Int64($0.tv_nsec) })
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        let entry = try entry(path)
        return FileMetadata(permissions: entry.permissions, modified: entry.modified, created: entry.created)
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? { nil }
    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile { throw refusal }
    public func readSymlink(_ path: VFSPath) async throws -> String { throw refusal }
    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] { throw refusal }
    public func createFile(_ path: VFSPath) async throws -> any WritableFile { throw refusal }
    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws { throw refusal }
    public func clone(_ from: VFSPath, to: VFSPath) async throws { throw refusal }
    public func remove(_ path: VFSPath) async throws { throw refusal }
    public func makeDirectory(_ path: VFSPath) async throws { throw refusal }
    public func synchronize(_ path: VFSPath) async throws {}
    public func createSymlink(_ path: VFSPath, target: String) async throws { throw refusal }
}

/// Opens .lst files as `FileListProvider`s and writes them from the pack dialog (the format
/// "File list (lst)"), like Total Commander's DiskDir plugin. Lists are never changed.
public final class FileListOpener: ContainerOpener, ContainerWriter {
    public init() {}

    public var provider: ProviderID { .fileList }

    public func recognizes(name: String) -> Bool { name.lowercased().hasSuffix(".lst") }

    public func open(_ file: FileItem, byContent: Bool, registry: ProviderRegistry) async throws -> (any FileSystemProvider)? {
        guard case .file = file.kind else { return nil }
        let local = file.path.location == .local ? URL(fileURLWithPath: file.path.path) : nil
        let data = try await Self.read(file.path, registry: registry)
        // DiskDir lists have no header, so only files named .lst are read as one.
        guard let parsed = FileListFormat.parse(data, diskDirAllowed: recognizes(name: file.name)) else { return nil }
        return FileListProvider(location: ProviderLocation(provider: .fileList, container: file.path), url: local, parsed: parsed)
    }

    public func test(_ file: VFSPath, registry: ProviderRegistry,
                     progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String] {
        let data = try await Self.read(file, registry: registry)
        guard let parsed = FileListFormat.parse(data, diskDirAllowed: recognizes(name: file.name)) else {
            throw VFSError.unsupported("\(file.name) is not a file list Basil can read")
        }
        progress(1, file.name)
        return parsed.problems
    }

    static func read(_ path: VFSPath, registry: ProviderRegistry) async throws -> Data {
        if path.location == .local {
            return try await ArchiveOpener.blocking { try Data(contentsOf: URL(fileURLWithPath: path.path)) }
        }
        let reader = try await registry.writableProvider(for: path.location).openForReading(path, bypassCache: false)
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try await reader.read(at: Int64(data.count), count: 1 << 20)
            if chunk.isEmpty { break }
            data += chunk
        }
        await reader.close()
        return data
    }

    // MARK: ContainerWriter

    /// The binary form (`FileListFormat.writeBinary`), quicker to write and open.
    public static let optimisedFormat = PackFormat(id: "lst-optimised", name: "Optimised file list (lst)", levels: [],
                                                   storesContents: false, fileExtension: "lst")
    /// The text form, readable in any editor.
    public static let textFormat = PackFormat(id: "lst", name: "File list, text (lst)", levels: [], storesContents: false)

    public var packFormats: [PackFormat] { [Self.optimisedFormat, Self.textFormat] }

    public func updateRefusal(for container: VFSPath, registry: ProviderRegistry) -> String? {
        fileListRefusal(container.name)
    }

    public func update(_ container: VFSPath, changes: [ContainerChange], macMetadata: Bool,
                       registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        throw VFSError.unsupported(fileListRefusal(container.name))
    }

    /// Writes the list of everything the adds name: one line per file, folder and link, with
    /// sizes, dates and permissions read from the sources' providers. Written to a partial file,
    /// synchronised, read back and compared, then renamed into place.
    public func create(_ destination: VFSPath, options: PackOptions, changes: [ContainerChange], replacing: Bool,
                       registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        guard destination.location == .local, let folder = destination.parent else {
            throw VFSError.unsupported("creating file lists outside local folders")
        }
        let target = URL(fileURLWithPath: destination.path)
        if !replacing, FileManager.default.fileExists(atPath: target.path) { throw VFSError.alreadyExists(destination) }

        var result = ContainerWriteResult()
        var entries: [FileListEntry] = []
        // The folder the first source is in (the adds start with the top-level sources).
        let rootFolder = changes.lazy.compactMap(\.source).first?.parent
        for (n, change) in changes.enumerated() {
            if n % 256 == 0 { try await monitor.checkpoint() }
            guard let at = change.addedPath else { continue }
            let path = FileListFormat.normalise(at)
            guard !path.isEmpty else { continue }
            guard let source = change.source else {
                entries.append(FileListEntry(path: path, kind: .directory))
                continue
            }
            while true {
                do {
                    let entry = try await Self.entry(for: source, path: path, registry: registry)
                    entries.append(entry)
                    if entry.kind == .file { monitor.written(bytes: entry.size ?? 0) }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if try await monitor.skipAfterError(error, at: source) {
                        result.skipped.append(source)
                        break
                    }
                }
            }
        }

        let root = rootFolder.map { $0.location == .local ? $0.path : $0.description } ?? ""
        let data = options.format == Self.textFormat.id ? Data(FileListFormat.write(root: root, entries: entries).utf8)
                                                        : FileListFormat.writeBinary(root: root, entries: entries)
        let partial = URL(fileURLWithPath: folder.appending(ArchiveOpener.partialName(destination.name)).path)
        let expected = entries
        do {
            try await ArchiveOpener.blocking {
                let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { throw VFSError.posix(code: errno, path: .local(partial.path)) }
                defer { Darwin.close(fd) }
                var written = 0
                try data.withUnsafeBytes { buffer in
                    while written < buffer.count {
                        let n = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
                        guard n > 0 else { throw VFSError.posix(code: errno, path: .local(partial.path)) }
                        written += n
                    }
                }
                guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                    throw VFSError.posix(code: errno, path: .local(partial.path))
                }
                // Read back: the list must give the same entries.
                guard let parsed = FileListFormat.parse(try Data(contentsOf: partial)), parsed.problems.isEmpty,
                      Self.same(parsed.entries, expected) else {
                    throw VFSError.unsupported("writing \(destination.name): the written list did not read back the same")
                }
            }
            let r = replacing ? Darwin.rename(partial.path, target.path)
                              : renamex_np(partial.path, target.path, UInt32(RENAME_EXCL))
            if r != 0 {
                if errno == EEXIST { throw VFSError.alreadyExists(destination) }
                throw VFSError.posix(code: errno, path: destination)
            }
        } catch {
            unlink(partial.path)
            throw error
        }
        result.entries = entries.count
        return result
    }

    /// Every expected entry reads back unchanged; anything else read back is a folder added for a path.
    static func same(_ read: [FileListEntry], _ expected: [FileListEntry]) -> Bool {
        var wanted: [String: FileListEntry] = [:]
        for e in expected { wanted[e.path] = e }
        var found = 0
        for e in read {
            if let w = wanted[e.path] {
                guard w == e else { return false }
                found += 1
            } else if e.kind != .directory {
                return false
            }
        }
        return found == wanted.count
    }

    private static func entry(for source: VFSPath, path: String, registry: ProviderRegistry) async throws -> FileListEntry {
        let item = try await registry.provider(for: source.location).item(at: source)
        let kind: FileListEntry.Kind
        var target: String?
        switch item.kind {
        case .file: kind = .file
        case .directory: kind = .directory
        case .symlink:
            kind = .symlink
            target = try? await registry.writableProvider(for: source.location).readSymlink(source)
        case .other: kind = .other
        }
        return FileListEntry(path: path, kind: kind, size: kind == .directory ? nil : item.size,
                             modified: item.modified.map(timespec.init), created: item.created.map(timespec.init),
                             permissions: item.permissions, symlinkTarget: target)
    }
}

extension timespec {
    init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: min(999_999_999, Int(((interval - seconds) * 1e9).rounded())))
    }
}
