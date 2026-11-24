import Darwin
import Foundation
import Synchronization

private func ag<T: BinaryInteger>(_ value: T) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: value) }

/// Scans a folder tree into an `IndexStore` with getattrlistbulk, one level at a time: the
/// folders of a level are listed in parallel, then their children are appended in order, so the
/// records come out breadth-first with every folder's children together.
struct IndexScanner: Sendable {
    /// Folders recorded but not entered (other volumes' mount points, /dev).
    var skippedPaths: Set<String>
    /// Devices whose folders are entered; nil enters every device.
    var devices: Set<Int32>?

    /// The startup disk: the system volume and the data volume (through its firmlinks), without
    /// /System/Volumes (which holds the data volume a second time), /Volumes and /dev.
    static func bootVolume() -> IndexScanner {
        var devices: Set<Int32> = []
        for path in ["/", "/System/Volumes/Data"] {
            var info = Darwin.stat()
            if lstat(path, &info) == 0 { devices.insert(info.st_dev) }
        }
        return IndexScanner(skippedPaths: ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/.vol", "/.Spotlight-V100",
                                           "/.fseventsd", "/.DocumentRevisions-V100", "/private/var/folders"],
                            devices: devices)
    }

    /// A volume other than the startup disk, mounted at `root`: only that device, without its
    /// Spotlight, FSEvents and version stores.
    static func volume(_ root: String) -> IndexScanner {
        var info = Darwin.stat()
        let devices: Set<Int32>? = lstat(root, &info) == 0 ? [info.st_dev] : nil
        let base = root == "/" ? "" : root
        return IndexScanner(skippedPaths: Set([".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"]
                                                .map { base + "/" + $0 }),
                            devices: devices)
    }

    /// Whether this scanner would index `path` (it is not in or below a skipped folder).
    func covers(_ path: String) -> Bool {
        !skippedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Scans `root`. `progress` gets the number of entries so far (from the scanning thread).
    func scan(_ root: String, isCancelled: @Sendable () -> Bool, progress: (Int) -> Void) throws -> IndexStore {
        let store = IndexStore()
        store.addRoot(root)
        var level: [(index: UInt32, path: String)] = [(0, root)]
        while !level.isEmpty {
            if isCancelled() { throw CancellationError() }
            let listed = listAll(level.map(\.path), isCancelled: isCancelled)
            var next: [(index: UInt32, path: String)] = []
            for (position, folder) in level.enumerated() {
                let entries = listed[position]
                let range = store.setChildren(of: folder.index, entries.map(\.item))
                var deviceOf: [String: Int32] = [:]
                for entry in entries where entry.item.kind == IndexRecord.kindDirectory { deviceOf[entry.item.name] = entry.device }
                for index in range where store.records[Int(index)].isDirectory {
                    let name = store.name(index)
                    let path = folder.path == "/" ? "/" + name : folder.path + "/" + name
                    let device = deviceOf[name]
                    if skippedPaths.contains(path) { continue }
                    if let devices, let device, !devices.contains(device) { continue }
                    next.append((index, path))
                }
            }
            progress(store.records.count)
            level = next
        }
        return store
    }

    /// Lists every folder (several at a time). Unreadable folders give no items.
    func listAll(_ folders: [String], isCancelled: @Sendable () -> Bool) -> [[(item: ScannedItem, device: Int32)]] {
        let results = Mutex([[(item: ScannedItem, device: Int32)]](repeating: [], count: folders.count))
        let chunk = max(1, folders.count / 64)
        DispatchQueue.concurrentPerform(iterations: (folders.count + chunk - 1) / chunk) { part in
            let range = (part * chunk)..<min(folders.count, (part + 1) * chunk)
            for i in range {
                if isCancelled() { return }
                let items = (try? Self.list(folders[i])) ?? []
                results.withLock { $0[i] = items }
            }
        }
        return results.withLock { $0 }
    }

    /// One folder's entries with the device each lives on.
    static func list(_ folder: String) throws -> [(item: ScannedItem, device: Int32)] {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let common: [attrgroup_t] = [ag(ATTR_CMN_RETURNED_ATTRS), ag(ATTR_CMN_ERROR), ag(ATTR_CMN_NAME), ag(ATTR_CMN_DEVID),
                                     ag(ATTR_CMN_OBJTYPE), ag(ATTR_CMN_CRTIME), ag(ATTR_CMN_MODTIME), ag(ATTR_CMN_ACCESSMASK),
                                     ag(ATTR_CMN_FLAGS)]
        attrs.commonattr = common.reduce(0, |)
        attrs.fileattr = ag(ATTR_FILE_DATALENGTH)
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var result: [(item: ScannedItem, device: Int32)] = []
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, size, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let parsed = parse(entry) { result.append(parsed) }
                entry += length
            }
        }
        return result
    }

    private static func parse(_ entry: UnsafeRawPointer) -> (item: ScannedItem, device: Int32)? {
        var p = entry + MemoryLayout<UInt32>.size
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        func has<T: BinaryInteger>(_ bit: T) -> Bool { returned.commonattr & ag(bit) != 0 }
        if has(ATTR_CMN_ERROR) {
            let error = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }
        guard has(ATTR_CMN_NAME) else { return nil }
        let ref = p.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size
        var device: Int32 = 0
        if has(ATTR_CMN_DEVID) {
            device = p.loadUnaligned(as: dev_t.self)
            p += MemoryLayout<dev_t>.size
        }
        var type = fsobj_type_t(VNON.rawValue)
        if has(ATTR_CMN_OBJTYPE) {
            type = p.loadUnaligned(as: fsobj_type_t.self)
            p += MemoryLayout<fsobj_type_t>.size
        }
        func millis(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1000 + Int64(t.tv_nsec) / 1_000_000 }
        var created = IndexRecord.unknownDate, modified = IndexRecord.unknownDate
        if has(ATTR_CMN_CRTIME) {
            created = millis(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        if has(ATTR_CMN_MODTIME) {
            modified = millis(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        var permissions: UInt16 = 0
        if has(ATTR_CMN_ACCESSMASK) {
            permissions = UInt16(p.loadUnaligned(as: UInt32.self) & 0o7777)
            p += MemoryLayout<UInt32>.size
        }
        var flags: UInt32 = 0
        if has(ATTR_CMN_FLAGS) {
            flags = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
        }
        var size: Int64 = 0
        if returned.fileattr & ag(ATTR_FILE_DATALENGTH) != 0 { size = p.loadUnaligned(as: off_t.self) }
        let kind: UInt8 = switch type {
        case fsobj_type_t(VREG.rawValue): IndexRecord.kindFile
        case fsobj_type_t(VDIR.rawValue): IndexRecord.kindDirectory
        case fsobj_type_t(VLNK.rawValue): IndexRecord.kindSymlink
        default: IndexRecord.kindOther
        }
        if kind != IndexRecord.kindFile { size = 0 }
        let item = ScannedItem(name: name, kind: kind, hidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0,
                               permissions: permissions, size: size, modified: modified, created: created)
        return (item, device)
    }

    /// One item's metadata (for changes FSEvents reports); nil when it does not exist.
    static func stat(_ path: String) -> (item: ScannedItem, device: Int32)? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        let type = info.st_mode & S_IFMT
        let kind: UInt8 = type == S_IFREG ? IndexRecord.kindFile : type == S_IFDIR ? IndexRecord.kindDirectory
            : type == S_IFLNK ? IndexRecord.kindSymlink : IndexRecord.kindOther
        func millis(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1000 + Int64(t.tv_nsec) / 1_000_000 }
        let item = ScannedItem(name: name, kind: kind, hidden: name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0,
                               permissions: UInt16(info.st_mode & 0o7777), size: kind == IndexRecord.kindFile ? info.st_size : 0,
                               modified: millis(info.st_mtimespec), created: millis(info.st_birthtimespec))
        return (item, info.st_dev)
    }
}
