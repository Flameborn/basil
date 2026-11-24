import BasilCore
import Foundation

/// One entry of the filename index, 56 bytes, stored as is (little-endian on Apple silicon).
/// Entries are in breadth-first order: a folder's children follow each other, sorted by their
/// UTF-8 names, from `firstChild` for `childCount` entries. Entries added later (by FSEvents)
/// are appended with `flagAppended` and found through `IndexStore.appendedChildren`.
struct IndexRecord {
    var parent: UInt32
    var firstChild: UInt32
    var childCount: UInt32
    var nameOffset: UInt32
    var foldedOffset: UInt32
    var nameLength: UInt16
    var foldedLength: UInt16
    var kind: UInt8
    var flags: UInt8
    var permissions: UInt16
    var size: Int64
    /// Milliseconds since 1970; Int64.min when unknown.
    var modified: Int64
    var created: Int64

    static let kindFile: UInt8 = 0, kindDirectory: UInt8 = 1, kindSymlink: UInt8 = 2, kindOther: UInt8 = 3
    static let flagHidden: UInt8 = 1, flagRemoved: UInt8 = 2, flagAppended: UInt8 = 4
    static let noParent = UInt32.max
    static let unknownDate = Int64.min

    var isRemoved: Bool { flags & Self.flagRemoved != 0 }
    var isHidden: Bool { flags & Self.flagHidden != 0 }
    var isDirectory: Bool { kind == Self.kindDirectory }

    static func millis(_ date: Date?) -> Int64 {
        guard let date else { return unknownDate }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func date(_ millis: Int64) -> Date? {
        millis == unknownDate ? nil : Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

/// What the scanner reports for one item.
struct ScannedItem {
    var name: String
    var kind: UInt8
    var hidden: Bool
    var permissions: UInt16
    var size: Int64
    var modified: Int64
    var created: Int64
}

/// The index data: records and the two name blobs (original and lowercased UTF-8). Not thread
/// safe: `FilenameIndex` (an actor) owns it. A loaded file is read into memory once.
final class IndexStore: @unchecked Sendable {
    static let magic = Array("BASILIDX".utf8)
    static let version: UInt32 = 1
    static let headerSize = 512

    var records: [IndexRecord] = []
    var names: [UInt8] = []
    var folded: [UInt8] = []
    /// Children added after the folder's own range was written, by folder index.
    var appendedChildren: [UInt32: [UInt32]] = [:]
    /// The root folder this index covers ("/").
    var rootPath = "/"
    /// The FSEvents ID up to which changes are applied.
    var lastEventID: UInt64 = 0
    /// Identifies the volume's FSEvents history (FSEventsCopyUUIDForDevice).
    var volumeUUID = ""
    var removedCount = 0

    var liveCount: Int { records.count - removedCount }

    init() {}

    // MARK: Building

    /// Adds the root folder record.
    func addRoot(_ path: String) {
        rootPath = path
        records = [IndexRecord(parent: IndexRecord.noParent, firstChild: 0, childCount: 0, nameOffset: 0, foldedOffset: 0,
                               nameLength: 0, foldedLength: 0, kind: IndexRecord.kindDirectory, flags: 0, permissions: 0,
                               size: 0, modified: IndexRecord.unknownDate, created: IndexRecord.unknownDate)]
    }

    func makeRecord(_ item: ScannedItem, parent: UInt32, flags extra: UInt8 = 0) -> IndexRecord {
        let nameBytes = Array(item.name.utf8)
        let foldedBytes = FoldedNameMatcher.fold(item.name)
        let record = IndexRecord(parent: parent, firstChild: 0, childCount: 0,
                                 nameOffset: UInt32(names.count), foldedOffset: UInt32(folded.count),
                                 nameLength: UInt16(min(nameBytes.count, Int(UInt16.max))),
                                 foldedLength: UInt16(min(foldedBytes.count, Int(UInt16.max))),
                                 kind: item.kind, flags: (item.hidden ? IndexRecord.flagHidden : 0) | extra,
                                 permissions: item.permissions, size: item.size, modified: item.modified, created: item.created)
        names += nameBytes
        folded += foldedBytes
        return record
    }

    /// Sets a folder's children (sorted by name) at the end of the records. Returns their indices.
    @discardableResult
    func setChildren(of folder: UInt32, _ items: [ScannedItem]) -> Range<UInt32> {
        let sorted = items.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let first = UInt32(records.count)
        for item in sorted { records.append(makeRecord(item, parent: folder)) }
        records[Int(folder)].firstChild = first
        records[Int(folder)].childCount = UInt32(sorted.count)
        return first..<UInt32(records.count)
    }

    // MARK: Names and paths

    func name(_ index: UInt32) -> String {
        let r = records[Int(index)]
        let start = Int(r.nameOffset)
        return String(decoding: names[start..<start + Int(r.nameLength)], as: UTF8.self)
    }

    func path(_ index: UInt32) -> String {
        var parts: [String] = []
        var i = index
        while i != 0, i != IndexRecord.noParent {
            parts.append(name(i))
            i = records[Int(i)].parent
        }
        let tail = parts.reversed().joined(separator: "/")
        if rootPath == "/" { return "/" + tail }
        return tail.isEmpty ? rootPath : rootPath + "/" + tail
    }

    /// The live child of `folder` named `name`, if any.
    func child(of folder: UInt32, named name: String) -> UInt32? {
        let target = Array(name.utf8)
        if let appended = appendedChildren[folder] {
            for index in appended.reversed() where !records[Int(index)].isRemoved && nameBytesEqual(index, target) { return index }
        }
        let r = records[Int(folder)]
        var low = Int(r.firstChild), high = Int(r.firstChild) + Int(r.childCount) - 1
        while low <= high {
            let mid = (low + high) / 2
            let order = compareName(UInt32(mid), target)
            if order == 0 { return records[mid].isRemoved ? nil : UInt32(mid) }
            if order < 0 { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func nameBytesEqual(_ index: UInt32, _ target: [UInt8]) -> Bool { compareName(index, target) == 0 }

    private func compareName(_ index: UInt32, _ target: [UInt8]) -> Int {
        let r = records[Int(index)]
        let start = Int(r.nameOffset), length = Int(r.nameLength)
        return names.withUnsafeBufferPointer { all in
            target.withUnsafeBufferPointer { t in
                let common = min(length, t.count)
                let c = memcmp(all.baseAddress! + start, t.baseAddress!, common)
                if c != 0 { return Int(c) }
                return length - t.count
            }
        }
    }

    /// The live entry at `path` (absolute), if indexed.
    func lookup(_ path: String) -> UInt32? {
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return nil }
        let relative = rootPath == "/" ? path.dropFirst() : path.dropFirst(rootPath.count)
        var index: UInt32 = 0
        for part in relative.split(separator: "/") {
            guard let next = child(of: index, named: String(part)) else { return nil }
            index = next
        }
        return index
    }

    /// Every live child of a folder (its range and the appended ones).
    func children(of folder: UInt32) -> [UInt32] {
        let r = records[Int(folder)]
        var result: [UInt32] = []
        for i in r.firstChild..<(r.firstChild + r.childCount) where !records[Int(i)].isRemoved { result.append(i) }
        for i in appendedChildren[folder] ?? [] where !records[Int(i)].isRemoved { result.append(i) }
        return result
    }

    // MARK: Changes

    /// Marks an entry removed (its descendants count as removed through it).
    func remove(_ index: UInt32) {
        guard index != 0, !records[Int(index)].isRemoved else { return }
        records[Int(index)].flags |= IndexRecord.flagRemoved
        removedCount += 1
    }

    /// Updates the entry's metadata in place when the kind is the same; otherwise replaces it.
    /// Returns the entry's index.
    @discardableResult
    func upsert(_ item: ScannedItem, in folder: UInt32) -> UInt32 {
        if let existing = child(of: folder, named: item.name), records[Int(existing)].kind == item.kind {
            var r = records[Int(existing)]
            r.size = item.size
            r.modified = item.modified
            r.created = item.created
            r.permissions = item.permissions
            r.flags = (r.flags & ~IndexRecord.flagHidden) | (item.hidden ? IndexRecord.flagHidden : 0)
            records[Int(existing)] = r
            return existing
        }
        if let existing = child(of: folder, named: item.name) { remove(existing) }
        let index = UInt32(records.count)
        records.append(makeRecord(item, parent: folder, flags: IndexRecord.flagAppended))
        appendedChildren[folder, default: []].append(index)
        return index
    }

    /// Whether the entry or a folder above it was removed; `hidden` reports a hidden one on the way.
    func isLive(_ index: UInt32, hiddenOnTheWay hidden: inout Bool) -> Bool {
        var i = index
        hidden = false
        while i != 0, i != IndexRecord.noParent {
            let r = records[Int(i)]
            if r.isRemoved { return false }
            if r.isHidden { hidden = true }
            i = r.parent
        }
        return true
    }

    /// Whether `index` is `ancestor` or below it.
    func isBelow(_ index: UInt32, _ ancestor: UInt32) -> Bool {
        if ancestor == 0 { return true }
        var i = index
        while i != IndexRecord.noParent {
            if i == ancestor { return true }
            if i == 0 { return false }
            i = records[Int(i)].parent
        }
        return false
    }

    /// Rebuilds the records in breadth-first order without removed entries (after many changes).
    func compacted() -> IndexStore {
        let result = IndexStore()
        result.addRoot(rootPath)
        result.lastEventID = lastEventID
        result.volumeUUID = volumeUUID
        var queue: [(old: UInt32, new: UInt32)] = [(0, 0)]
        var head = 0
        while head < queue.count {
            let (old, new) = queue[head]
            head += 1
            let kids = children(of: old).sorted { a, b in compareName(a, Array(name(b).utf8)) < 0 }
            let first = UInt32(result.records.count)
            for kid in kids {
                let r = records[Int(kid)]
                let item = ScannedItem(name: name(kid), kind: r.kind, hidden: r.isHidden, permissions: r.permissions,
                                       size: r.size, modified: r.modified, created: r.created)
                result.records.append(result.makeRecord(item, parent: new))
            }
            result.records[Int(new)].firstChild = first
            result.records[Int(new)].childCount = UInt32(kids.count)
            for (offset, kid) in kids.enumerated() where records[Int(kid)].isDirectory {
                queue.append((kid, first + UInt32(offset)))
            }
        }
        return result
    }

    var needsCompaction: Bool {
        let appended = appendedChildren.values.reduce(0) { $0 + $1.count }
        return removedCount + appended > max(10_000, records.count / 10)
    }

    // MARK: File

    /// Writes the index through a partial file renamed into place.
    func write(to url: URL) throws {
        var header = [UInt8](repeating: 0, count: Self.headerSize)
        func put<T>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value) { bytes in for (i, b) in bytes.enumerated() { header[offset + i] = b } }
        }
        for (i, b) in Self.magic.enumerated() { header[i] = b }
        put(Self.version, at: 8)
        put(UInt32(MemoryLayout<IndexRecord>.stride), at: 12)
        put(UInt64(records.count), at: 16)
        put(UInt64(names.count), at: 24)
        put(UInt64(folded.count), at: 32)
        put(lastEventID, at: 40)
        let uuid = Array(volumeUUID.utf8.prefix(40))
        put(UInt16(uuid.count), at: 48)
        for (i, b) in uuid.enumerated() { header[50 + i] = b }
        let root = Array(rootPath.utf8.prefix(Self.headerSize - 92))
        put(UInt16(root.count), at: 90)
        for (i, b) in root.enumerated() { header[92 + i] = b }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".basil-partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.write(contentsOf: Data(header))
            try records.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: Data(names))
            try handle.write(contentsOf: Data(folded))
            try handle.synchronize()
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    enum ReadError: Error { case notAnIndex, wrongVersion }

    static func read(from url: URL) throws -> IndexStore {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= headerSize, Array(data.prefix(8)) == magic else { throw ReadError.notAnIndex }
        func get<T>(_ type: T.Type, at offset: Int) -> T {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard get(UInt32.self, at: 8) == version, Int(get(UInt32.self, at: 12)) == MemoryLayout<IndexRecord>.stride else {
            throw ReadError.wrongVersion
        }
        let count = Int(get(UInt64.self, at: 16)), namesCount = Int(get(UInt64.self, at: 24)), foldedCount = Int(get(UInt64.self, at: 32))
        let recordBytes = count * MemoryLayout<IndexRecord>.stride
        guard data.count == headerSize + recordBytes + namesCount + foldedCount, count > 0 else { throw ReadError.notAnIndex }
        let store = IndexStore()
        store.lastEventID = get(UInt64.self, at: 40)
        let uuidLength = Int(get(UInt16.self, at: 48))
        store.volumeUUID = String(decoding: data[50..<50 + min(uuidLength, 40)], as: UTF8.self)
        let rootLength = Int(get(UInt16.self, at: 90))
        store.rootPath = String(decoding: data[92..<92 + min(rootLength, headerSize - 92)], as: UTF8.self)
        store.records = [IndexRecord](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { raw in
                _ = memcpy(buffer.baseAddress!, raw.baseAddress! + headerSize, recordBytes)
            }
            initialized = count
        }
        let namesStart = headerSize + recordBytes
        store.names = [UInt8](data[namesStart..<namesStart + namesCount])
        store.folded = [UInt8](data[(namesStart + namesCount)...])
        for (i, r) in store.records.enumerated() {
            if r.isRemoved { store.removedCount += 1 }
            if r.flags & IndexRecord.flagAppended != 0 { store.appendedChildren[r.parent, default: []].append(UInt32(i)) }
        }
        return store
    }
}
