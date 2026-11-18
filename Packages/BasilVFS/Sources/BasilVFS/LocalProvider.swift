import BasilCore
import Darwin
import Dispatch
import Foundation

/// The local file system. Listing uses `getattrlistbulk(2)`, which returns many
/// entries with their attributes per syscall (far faster than readdir + stat).
public struct LocalProvider: FileSystemProvider {
    public let location = ProviderLocation.local
    public let capabilities: ProviderCapabilities = [
        .read, .write, .randomAccessRead, .randomAccessWrite, .rename, .atomicRename,
        .setPermissions, .setDates, .extendedAttrs, .clone, .watch, .symlinks,
    ]

    /// Listing runs on its own queue: getattrlistbulk blocks and must not occupy the cooperative pool.
    private static let ioQueue = DispatchQueue(label: "basil.local.list", qos: .userInitiated, attributes: .concurrent)

    public init() {}

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancellationFlag()
            continuation.onTermination = { _ in cancelled.set() }
            Self.ioQueue.async {
                do {
                    try BulkLister.list(directory, isCancelled: cancelled.isSet) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        try Self.lstatItem(path)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? {
        DirectoryWatcher.stream(for: directory)
    }

    static func lstatItem(_ path: VFSPath) throws -> FileItem {
        var st = Darwin.stat()
        guard lstat(path.path, &st) == 0 else { throw posixError(errno, path) }
        let name = path.name
        let kind: FileItem.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink(target: symlinkTarget(path.path))
        default: kind = .other
        }
        return FileItem(
            path: path,
            kind: kind,
            size: kind == .file ? Int64(st.st_size) : nil,
            modified: Date(timespec: st.st_mtimespec),
            created: Date(timespec: st.st_birthtimespec),
            permissions: UInt16(st.st_mode & 0o7777),
            isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
            fileID: UInt64(st.st_ino)
        )
    }

    static func symlinkTarget(_ path: String) -> FileItem.Kind.Target {
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else { return .broken }
        return (st.st_mode & S_IFMT) == S_IFDIR ? .directory : .file
    }

    static func posixError(_ code: Int32, _ path: VFSPath) -> VFSError {
        switch code {
        case ENOENT: .notFound(path)
        case ENOTDIR: .notADirectory(path)
        case EACCES, EPERM: .permissionDenied(path)
        default: .posix(code: code, path: path)
        }
    }
}

final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func set() { flag.store(true, ordering: .relaxed) }
    var isSet: @Sendable () -> Bool { { self.flag.load(ordering: .relaxed) } }
}

import Synchronization

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

/// Parses `getattrlistbulk` output. Attribute order in each entry follows the bit
/// order of the requested attributes, with ATTR_CMN_RETURNED_ATTRS first and
/// ATTR_CMN_ERROR right after it (see getattrlist(2)).
private func ag<T: BinaryInteger>(_ value: T) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: value) }

enum BulkLister {
    static let batchSize = 2048
    static let bufferSize = 256 * 1024

    static func list(_ directory: VFSPath, isCancelled: () -> Bool, emit: ([FileItem]) -> Void) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw LocalProvider.posixError(errno, directory) }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let common: [attrgroup_t] = [
            ag(ATTR_CMN_RETURNED_ATTRS), ag(ATTR_CMN_ERROR), ag(ATTR_CMN_NAME), ag(ATTR_CMN_OBJTYPE),
            ag(ATTR_CMN_CRTIME), ag(ATTR_CMN_MODTIME), ag(ATTR_CMN_ACCESSMASK), ag(ATTR_CMN_FLAGS), ag(ATTR_CMN_FILEID),
        ]
        attrs.commonattr = common.reduce(0, |)
        attrs.fileattr = ag(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var batch: [FileItem] = []
        batch.reserveCapacity(batchSize)

        while !isCancelled() {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 { throw LocalProvider.posixError(errno, directory) }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = parseEntry(entry, directory: directory) {
                    batch.append(item)
                    if batch.count >= batchSize {
                        emit(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                entry += length
            }
        }
        if !batch.isEmpty { emit(batch) }
    }

    private static func parseEntry(_ entry: UnsafeRawPointer, directory: VFSPath) -> FileItem? {
        var p = entry + MemoryLayout<UInt32>.size // skip length
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        let common = returned.commonattr
        func has<T: BinaryInteger>(_ bit: T) -> Bool { common & ag(bit) != 0 }

        if has(ATTR_CMN_ERROR) {
            let err = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
            if err != 0 { return nil } // entry vanished or is unreadable; skip it
        }

        guard has(ATTR_CMN_NAME) else { return nil }
        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let namePtr = (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePtr)
        p += MemoryLayout<attrreference_t>.size

        var objType = fsobj_type_t(VNON.rawValue)
        if has(ATTR_CMN_OBJTYPE) {
            objType = p.loadUnaligned(as: fsobj_type_t.self)
            p += MemoryLayout<fsobj_type_t>.size
        }
        var created: Date?
        if has(ATTR_CMN_CRTIME) {
            created = Date(timespec: p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        var modified: Date?
        if has(ATTR_CMN_MODTIME) {
            modified = Date(timespec: p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        var permissions: UInt16?
        if has(ATTR_CMN_ACCESSMASK) {
            permissions = UInt16(p.loadUnaligned(as: UInt32.self) & 0o7777)
            p += MemoryLayout<UInt32>.size
        }
        var flags: UInt32 = 0
        if has(ATTR_CMN_FLAGS) {
            flags = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
        }
        var fileID: UInt64?
        if has(ATTR_CMN_FILEID) {
            fileID = p.loadUnaligned(as: UInt64.self)
            p += MemoryLayout<UInt64>.size
        }

        var size: Int64?
        if returned.fileattr & ag(ATTR_FILE_DATALENGTH) != 0 {
            size = p.loadUnaligned(as: off_t.self)
        }

        let path = directory.appending(name)
        let kind: FileItem.Kind
        switch objType {
        case fsobj_type_t(VREG.rawValue): kind = .file
        case fsobj_type_t(VDIR.rawValue): kind = .directory; size = nil
        case fsobj_type_t(VLNK.rawValue): kind = .symlink(target: LocalProvider.symlinkTarget(path.path)); size = nil
        default: kind = .other
        }

        return FileItem(
            path: path, kind: kind, size: size, modified: modified, created: created,
            permissions: permissions,
            isHidden: name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0,
            fileID: fileID
        )
    }
}
