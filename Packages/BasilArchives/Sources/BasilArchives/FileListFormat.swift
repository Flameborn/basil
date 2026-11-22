import Darwin
import Foundation

/// One item of a file list (.lst), with a path relative to the list's root ("Album/track.mp3").
public struct FileListEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, other }

    public var path: String
    public var kind: Kind
    public var size: Int64?
    public var modified: timespec?
    public var created: timespec?
    public var permissions: UInt16?
    public var symlinkTarget: String?

    public init(path: String, kind: Kind, size: Int64? = nil, modified: timespec? = nil, created: timespec? = nil,
                permissions: UInt16? = nil, symlinkTarget: String? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.permissions = permissions
        self.symlinkTarget = symlinkTarget
    }

    public static func == (a: Self, b: Self) -> Bool {
        func eq(_ x: timespec?, _ y: timespec?) -> Bool { x?.tv_sec == y?.tv_sec && x?.tv_nsec == y?.tv_nsec }
        return a.path == b.path && a.kind == b.kind && a.size == b.size && eq(a.modified, b.modified)
            && eq(a.created, b.created) && a.permissions == b.permissions && a.symlinkTarget == b.symlinkTarget
    }
}

/// File lists like Total Commander's DiskDir plugin: a text file that records a folder tree
/// (names, sizes, dates) so it can be browsed later like a folder, without the files.
///
/// Basil writes its own format (UTF-8, one line per item, tab-separated):
///
///     # Basil file list 1
///     # Root: /Users/erion/Music
///     # Columns: kind, size, modified, created, permissions, path, link target
///     D	-	2026-11-01T10:00:00.5Z	2026-10-01T09:00:00Z	755	Album
///     F	4523110	2026-11-01T10:00:00Z	-	644	Album/track.mp3
///
/// Kinds are F (file), D (folder), L (symbolic link) and O (other); "-" is a missing value;
/// dates are UTC with up to nine fraction digits; permissions are octal. In paths and link
/// targets a backslash, tab, line feed and carriage return are written as \\, \t, \n and \r.
///
/// It also reads DiskDir's format: the root on the first line (`C:\Music\`), then
/// `path<TAB>size<TAB>yyyy.m.d<TAB>h:mm.ss` with backslashes, folders ending in a backslash, local
/// times, UTF-8 or Windows-1252 text.
public enum FileListFormat {
    public static let header = "# Basil file list 1"
    static let rootPrefix = "# Root: "
    static let columns = "# Columns: kind, size, modified, created, permissions, path, link target"

    public enum Flavor: Sendable, Equatable { case basil, optimised, diskDir }

    public struct Parsed: Sendable {
        public var flavor: Flavor
        /// The folder the list was made of, as written in the file.
        public var root: String?
        public var entries: [FileListEntry]
        /// Lines that could not be read ("line 12: no size").
        public var problems: [String]
    }

    // MARK: Writing

    public static func write(root: String, entries: [FileListEntry]) -> String {
        var text = header + "\n" + rootPrefix + escape(root) + "\n" + columns + "\n"
        text.reserveCapacity(entries.count * 80)
        for e in entries {
            let kind = switch e.kind {
            case .file: "F"
            case .directory: "D"
            case .symlink: "L"
            case .other: "O"
            }
            var fields = [kind, e.size.map(String.init) ?? "-", e.modified.map(date) ?? "-", e.created.map(date) ?? "-",
                          e.permissions.map { String($0, radix: 8) } ?? "-", escape(e.path)]
            if let target = e.symlinkTarget { fields.append(escape(target)) }
            text += fields.joined(separator: "\t") + "\n"
        }
        return text
    }

    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return s }
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// "2026-11-01T10:00:00.5Z" (UTC, fraction without trailing zeros).
    static func date(_ t: timespec) -> String {
        var seconds = t.tv_sec
        var tm = Darwin.tm()
        gmtime_r(&seconds, &tm)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1,
                          Int(tm.tm_mday), Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec))
        if t.tv_nsec > 0 {
            var fraction = String(format: "%09d", Int(t.tv_nsec))
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text + "Z"
    }

    static func parseDate(_ s: Substring) -> timespec? {
        guard s != "-", s.hasSuffix("Z") else { return nil }
        let body = s.dropLast()
        let parts = body.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let timeAndFraction = parts[1].split(separator: ".", maxSplits: 1)
        let time = timeAndFraction[0].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count == 3 else { return nil }
        var tm = Darwin.tm()
        tm.tm_year = Int32(day[0] - 1900)
        tm.tm_mon = Int32(day[1] - 1)
        tm.tm_mday = Int32(day[2])
        tm.tm_hour = Int32(time[0])
        tm.tm_min = Int32(time[1])
        tm.tm_sec = Int32(time[2])
        var nanos = 0
        if timeAndFraction.count == 2 {
            let digits = timeAndFraction[1].prefix(9)
            guard let value = Int(digits) else { return nil }
            nanos = value * Int(pow(10, Double(9 - digits.count)))
        }
        return timespec(tv_sec: timegm(&tm), tv_nsec: nanos)
    }

    // MARK: Reading

    /// Reads a file list, or returns nil when `data` is not one. `diskDirAllowed` accepts the
    /// DiskDir format (it has no header, so only files named .lst are tried).
    public static func parse(_ data: Data, diskDirAllowed: Bool = true) -> Parsed? {
        if data.starts(with: binaryMagic) { return parseBinary(data) }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        if bytes.starts(with: Array(header.utf8)) {
            guard let text = String(data: bytes, encoding: .utf8) else { return nil }
            return parseBasil(text)
        }
        guard diskDirAllowed else { return nil }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) else { return nil }
        return parseDiskDir(text)
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
    }

    private static func parseBasil(_ text: String) -> Parsed {
        var result = Parsed(flavor: .basil, root: nil, entries: [], problems: [])
        for (n, line) in lines(text).enumerated() {
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix(rootPrefix) { result.root = unescape(line.dropFirst(rootPrefix.count)) }
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6 else {
                result.problems.append("Line \(n + 1): not enough columns")
                continue
            }
            let kind: FileListEntry.Kind
            switch fields[0] {
            case "F": kind = .file
            case "D": kind = .directory
            case "L": kind = .symlink
            case "O": kind = .other
            default:
                result.problems.append("Line \(n + 1): unknown kind \(fields[0])")
                continue
            }
            let path = normalise(unescape(fields[5]))
            guard !path.isEmpty else {
                result.problems.append("Line \(n + 1): no name")
                continue
            }
            result.entries.append(FileListEntry(
                path: path, kind: kind, size: Int64(fields[1]),
                modified: parseDate(fields[2]), created: parseDate(fields[3]),
                permissions: UInt16(fields[4], radix: 8),
                symlinkTarget: fields.count > 6 ? unescape(fields[6]) : nil))
        }
        return result
    }

    /// DiskDir: a root line without tabs, then items with at least a size column.
    private static func parseDiskDir(_ text: String) -> Parsed? {
        let all = lines(text)
        guard let first = all.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let root = all[first]
        guard !root.contains("\t") else { return nil }
        var result = Parsed(flavor: .diskDir, root: String(root), entries: [], problems: [])
        for n in all.indices where n > first {
            let line = all[n]
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let size = Int64(fields[1].trimmingCharacters(in: .whitespaces)) else {
                // Not DiskDir at all when the first item line is already wrong.
                if result.entries.isEmpty, result.problems.isEmpty { return nil }
                result.problems.append("Line \(n + 1): no size")
                continue
            }
            var name = String(fields[0])
            let isFolder = name.hasSuffix("\\")
            name = name.replacingOccurrences(of: "\\", with: "/")
            let path = normalise(name)
            guard !path.isEmpty else { continue }
            let modified = fields.count >= 4 ? diskDirDate(fields[2], fields[3]) : nil
            result.entries.append(FileListEntry(path: path, kind: isFolder ? .directory : .file,
                                                size: isFolder ? nil : size, modified: modified))
        }
        return result
    }

    /// "2010.5.3" and "14:22.10" (local time).
    static func diskDirDate(_ day: Substring, _ time: Substring) -> timespec? {
        let d = day.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let t = time.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard d.count == 3 else { return nil }
        var tm = Darwin.tm()
        tm.tm_year = Int32(d[0] - 1900)
        tm.tm_mon = Int32(d[1] - 1)
        tm.tm_mday = Int32(d[2])
        tm.tm_hour = Int32(t.count > 0 ? t[0] : 0)
        tm.tm_min = Int32(t.count > 1 ? t[1] : 0)
        tm.tm_sec = Int32(t.count > 2 ? t[2] : 0)
        tm.tm_isdst = -1
        let seconds = mktime(&tm)
        return seconds == -1 ? nil : timespec(tv_sec: seconds, tv_nsec: 0)
    }

    /// "a//b/" -> "a/b"; leading slashes and "." parts dropped, ".." parts refused (empty).
    static func normalise(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { return "" }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }
}

// MARK: Optimised (binary) file lists

/// "Optimised file list": the same facts in a compact binary form that is quicker to write and
/// read than the text form (no date or number parsing, each name stored once).
///
///     magic "BASILLST" (8 bytes), version u16 = 1, flags u16 = 0
///     root: u32 byte count + UTF-8
///     entry count: u64
///     per entry, parents before their children:
///         kind u8 (0 file, 1 folder, 2 link, 3 other), present u8 (bit 0 size, 1 modified,
///         2 created, 3 permissions, 4 link target), parent u32 (index of an earlier folder
///         entry, 0xFFFFFFFF for the root), name: u16 byte count + UTF-8,
///         then the present fields: size i64, modified i64 seconds + u32 nanoseconds,
///         created the same, permissions u16, link target u32 byte count + UTF-8
///     end marker "END!" (4 bytes)
///
/// Numbers are little-endian. A list that is cut short or has a bad parent fails to open.
extension FileListFormat {
    static let binaryMagic = Data("BASILLST".utf8)
    static let binaryEnd = Data("END!".utf8)
    static let noParent: UInt32 = .max

    public static func writeBinary(root: String, entries: [FileListEntry]) -> Data {
        // Every parent folder needs an entry of its own, ahead of its children.
        var indexOf: [String: UInt32] = [:]
        var ordered: [(entry: FileListEntry, parent: UInt32, name: String)] = []
        ordered.reserveCapacity(entries.count)
        func ensureFolder(_ path: String) -> UInt32 {
            if path.isEmpty { return noParent }
            if let i = indexOf[path] { return i }
            let (parentPath, name) = split(path)
            let parent = ensureFolder(parentPath)
            let i = UInt32(ordered.count)
            ordered.append((FileListEntry(path: path, kind: .directory), parent, name))
            indexOf[path] = i
            return i
        }
        for entry in entries {
            let (parentPath, name) = split(entry.path)
            let parent = ensureFolder(parentPath)
            if let existing = indexOf[entry.path] {
                ordered[Int(existing)].entry = entry // an explicit folder after its implied one
                continue
            }
            indexOf[entry.path] = UInt32(ordered.count)
            ordered.append((entry, parent, name))
        }

        var out = Data()
        out.reserveCapacity(64 + ordered.count * 48)
        out += binaryMagic
        out.appendLE(UInt16(1))
        out.appendLE(UInt16(0))
        out.appendString32(root)
        out.appendLE(UInt64(ordered.count))
        for (e, parent, name) in ordered {
            let kind: UInt8 = switch e.kind {
            case .file: 0
            case .directory: 1
            case .symlink: 2
            case .other: 3
            }
            var present: UInt8 = 0
            if e.size != nil { present |= 1 }
            if e.modified != nil { present |= 2 }
            if e.created != nil { present |= 4 }
            if e.permissions != nil { present |= 8 }
            if e.symlinkTarget != nil { present |= 16 }
            out.append(kind)
            out.append(present)
            out.appendLE(parent)
            let nameBytes = Data(name.utf8)
            out.appendLE(UInt16(min(nameBytes.count, Int(UInt16.max))))
            out += nameBytes.prefix(Int(UInt16.max))
            if let size = e.size { out.appendLE(UInt64(bitPattern: size)) }
            for t in [e.modified, e.created] {
                if let t {
                    out.appendLE(UInt64(bitPattern: Int64(t.tv_sec)))
                    out.appendLE(UInt32(t.tv_nsec))
                }
            }
            if let p = e.permissions { out.appendLE(p) }
            if let target = e.symlinkTarget { out.appendString32(target) }
        }
        out += binaryEnd
        return out
    }

    /// "a/b/c" -> ("a/b", "c").
    private static func split(_ path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    static func parseBinary(_ data: Data) -> Parsed? {
        var r = BinaryReader(data: data, offset: binaryMagic.count)
        guard let version: UInt16 = r.read(), version == 1, let _: UInt16 = r.read(),
              let root = r.string32(), let count: UInt64 = r.read(), count < UInt64(data.count) else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(Int(count))
        var isFolder: [Bool] = []
        var entries: [FileListEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let kindByte: UInt8 = r.read(), let present: UInt8 = r.read(), let parent: UInt32 = r.read(),
                  let nameCount: UInt16 = r.read(), let name = r.string(Int(nameCount)) else { return nil }
            let kind: FileListEntry.Kind
            switch kindByte {
            case 0: kind = .file
            case 1: kind = .directory
            case 2: kind = .symlink
            default: kind = .other
            }
            let path: String
            if parent == noParent {
                path = name
            } else {
                guard Int(parent) < paths.count, isFolder[Int(parent)] else { return nil }
                path = paths[Int(parent)] + "/" + name
            }
            var e = FileListEntry(path: path, kind: kind)
            if present & 1 != 0 { guard let v: UInt64 = r.read() else { return nil }; e.size = Int64(bitPattern: v) }
            if present & 2 != 0 { guard let t = r.time() else { return nil }; e.modified = t }
            if present & 4 != 0 { guard let t = r.time() else { return nil }; e.created = t }
            if present & 8 != 0 { guard let p: UInt16 = r.read() else { return nil }; e.permissions = p }
            if present & 16 != 0 { guard let t = r.string32() else { return nil }; e.symlinkTarget = t }
            paths.append(path)
            isFolder.append(kind == .directory)
            entries.append(e)
        }
        guard r.string(binaryEnd.count) == "END!" else { return nil }
        return Parsed(flavor: .optimised, root: root, entries: entries, problems: [])
    }
}

private struct BinaryReader {
    let data: Data
    var offset: Int

    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        let start = data.startIndex + offset
        for i in 0..<size { value |= T(data[start + i]) << (8 * i) }
        offset += size
        return value
    }

    mutating func string(_ count: Int) -> String? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += count
        return String(decoding: data[start..<start + count], as: UTF8.self)
    }

    mutating func string32() -> String? {
        guard let n: UInt32 = read() else { return nil }
        return string(Int(n))
    }

    mutating func time() -> timespec? {
        guard let s: UInt64 = read(), let ns: UInt32 = read() else { return nil }
        return timespec(tv_sec: Int(Int64(bitPattern: s)), tv_nsec: Int(ns))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendString32(_ s: String) {
        let bytes = Data(s.utf8)
        appendLE(UInt32(bytes.count))
        append(bytes)
    }
}

/// The folder tree of a file list. Folders that appear only as part of a path are added.
struct FileListIndex: Sendable {
    /// By absolute path inside the list ("/Album/track.mp3").
    private(set) var entries: [String: FileListEntry] = [:]
    private(set) var children: [String: [String]] = ["/": []]

    init(_ list: [FileListEntry]) {
        for var entry in list {
            entry.path = "/" + entry.path
            add(entry)
        }
    }

    static let root = FileListEntry(path: "/", kind: .directory)

    func entry(_ path: String) -> FileListEntry? { path == "/" ? Self.root : entries[path] }

    private mutating func add(_ entry: FileListEntry) {
        let parent = ArchiveIndex.parent(of: entry.path)
        ensureFolder(parent)
        if let existing = entries[entry.path] {
            // A folder that already has children stays a folder.
            if existing.kind == .directory, entry.kind != .directory, children[entry.path]?.isEmpty == false { return }
        } else {
            children[parent, default: []].append(ArchiveIndex.name(of: entry.path))
        }
        entries[entry.path] = entry
        if entry.kind == .directory, children[entry.path] == nil { children[entry.path] = [] }
    }

    private mutating func ensureFolder(_ path: String) {
        guard path != "/" else { return }
        if let existing = entries[path] {
            if existing.kind != .directory {
                entries[path] = FileListEntry(path: path, kind: .directory, modified: existing.modified)
            }
            if children[path] == nil { children[path] = [] }
            return
        }
        ensureFolder(ArchiveIndex.parent(of: path))
        entries[path] = FileListEntry(path: path, kind: .directory)
        children[path] = []
        children[ArchiveIndex.parent(of: path), default: []].append(ArchiveIndex.name(of: path))
    }
}
