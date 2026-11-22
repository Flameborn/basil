import BasilCore
import CArchive
import Foundation

/// Reads zip, tar (plain or compressed with gzip, bzip2, xz, lzma, zstd, lz4, compress),
/// single compressed files, cpio, ISO 9660, xar, cab, lha and ar through libarchive.
/// 7z and RAR are left to their own backends (decision 2026-11-22).
public struct LibArchiveBackend: ArchiveBackend {
    public var name: String { "libarchive" }

    /// Names Enter opens. Formats that are really zip files (docx, jar, apk, ...) are opened
    /// only with Cmd+PageDown, like Total Commander.
    static let archiveSuffixes: Set<String> = [
        "zip", "tar", "tgz", "tar.gz", "tbz", "tbz2", "tar.bz2", "txz", "tar.xz",
        "tzst", "tar.zst", "tar.lz4", "tlz", "tar.lzma", "taz", "tar.z",
        "cpio", "iso", "xar", "cab", "lha", "lzh",
    ]
    /// A single compressed file. Shown as an archive with one entry: the name without the suffix.
    static let compressedSuffixes: Set<String> = ["gz", "bz2", "xz", "zst", "lz4", "lzma", "z"]

    public init() {}

    public func recognizes(name: String) -> Bool {
        let suffixes = ArchiveNames.suffixes(of: name)
        return suffixes.contains { Self.archiveSuffixes.contains($0) || Self.compressedSuffixes.contains($0) }
    }

    /// Whether the raw format is enabled: only for names ending in a compression suffix, because
    /// raw accepts any compressed stream and would hide real formats behind it otherwise.
    static func allowsRaw(_ url: URL) -> Bool {
        let suffixes = ArchiveNames.suffixes(of: url.lastPathComponent)
        guard let last = suffixes.first, compressedSuffixes.contains(last) else { return false }
        return !suffixes.contains { archiveSuffixes.contains($0) }
    }

    /// The name of a raw entry: the archive name without its compression suffix ("notes.txt.gz" -> "notes.txt").
    static func rawEntryName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name + ".data" }
        return String(name[..<dot])
    }

    public func entries(of url: URL, byContent: Bool) throws -> [ArchiveEntry]? {
        let reader = try LibArchiveReader(url: url, raw: Self.allowsRaw(url))
        guard let reader else { return nil }
        var entries: [ArchiveEntry] = []
        var ordinalByPath: [String: Int] = [:]
        while let header = try reader.nextHeader() {
            var entry = header.entry(ordinal: entries.count)
            if reader.isRaw { entry.path = "/" + Self.rawEntryName(for: url) }
            guard entry.path != "/" else {
                entries.append(entry) // keep ordinals in step with the archive
                continue
            }
            if let link = header.hardlink, let target = ordinalByPath[link] {
                entry.kind = .file
                entry.dataOrdinal = entries[target].dataOrdinal
                entry.size = entries[target].size
            }
            ordinalByPath[entry.path] = entry.ordinal
            entries.append(entry)
        }
        return entries
    }

    public func session(for url: URL, byContent: Bool) -> any ArchiveReadSession {
        LibArchiveSession(url: url)
    }

    public func test(_ url: URL, byContent: Bool, progress: (Double, String) -> Bool) throws -> [String] {
        guard let reader = try LibArchiveReader(url: url, raw: Self.allowsRaw(url)) else {
            throw ArchiveError.damaged("Not an archive libarchive reads", archive: url.lastPathComponent)
        }
        let total = max(1, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 1)
        var problems: [String] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while let header = try reader.nextHeader() {
            let name = reader.isRaw ? Self.rawEntryName(for: url) : String(header.path.dropFirst())
            let fraction = min(1, Double(reader.compressedBytesRead) / Double(total))
            guard progress(fraction, name) else { throw CancellationError() }
            if header.isEncrypted {
                problems.append("\(name): encrypted, not tested")
                continue
            }
            do {
                while try reader.readData(into: &buffer) > 0 {
                    let fraction = min(1, Double(reader.compressedBytesRead) / Double(total))
                    guard progress(fraction, name) else { throw CancellationError() }
                }
            } catch let error as ArchiveError {
                problems.append("\(name): \(error.localizedDescription)")
                if reader.isFatal { throw error }
            }
        }
        _ = progress(1, "")
        return problems
    }
}

/// Reads entry data with one libarchive handle, moving forward through the archive. Reading an
/// entry before the current one (or an earlier offset) reopens the archive, so extracting in
/// archive order reads the file once.
final class LibArchiveSession: ArchiveReadSession {
    private let url: URL
    private var reader: LibArchiveReader?
    private var current = -1
    private var consumed: Int64 = 0
    private var scratch = [UInt8](repeating: 0, count: 1 << 16)

    init(url: URL) { self.url = url }

    func read(_ entry: ArchiveEntry, at offset: Int64, count: Int) throws -> Data {
        let target = entry.dataOrdinal
        if reader == nil || current > target || (current == target && consumed > offset) {
            reader = try LibArchiveReader(url: url, raw: LibArchiveBackend.allowsRaw(url))
            current = -1
            guard reader != nil else { throw ArchiveError.damaged("The archive can no longer be read", archive: url.lastPathComponent) }
        }
        guard let reader else { throw ArchiveError.entryNotFound(entry.path) }
        while current < target {
            guard let header = try reader.nextHeader() else {
                self.reader = nil
                throw ArchiveError.entryNotFound(entry.path)
            }
            current += 1
            consumed = 0
            if current == target, header.isEncrypted { throw ArchiveError.encrypted(entry: String(entry.path.dropFirst())) }
        }
        while consumed < offset {
            let want = Int(min(Int64(scratch.count), offset - consumed))
            let n = try reader.readData(into: &scratch, limit: want)
            if n == 0 { return Data() }
            consumed += Int64(n)
        }
        var out = Data(count: count)
        var filled = 0
        try out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while filled < count {
                let n = try reader.readData(into: base + filled, count: count - filled)
                if n == 0 { break }
                filled += n
            }
        }
        consumed += Int64(filled)
        out.count = filled
        return out
    }
}

/// One header as libarchive reports it.
struct LibArchiveHeader {
    var path: String
    var type: UInt32
    var size: Int64?
    var modified: timespec?
    var permissions: UInt16
    var symlink: String?
    /// Normalised path of the entry this one is a hard link to.
    var hardlink: String?
    var isEncrypted: Bool

    func entry(ordinal: Int) -> ArchiveEntry {
        let kind: ArchiveEntry.Kind = switch type {
        case 0o100000: .file
        case 0o040000: .directory
        case 0o120000: .symlink
        default: .other
        }
        return ArchiveEntry(path: path, kind: kind, size: kind == .file ? size : nil, modified: modified,
                            permissions: permissions, symlinkTarget: kind == .symlink ? symlink : nil,
                            isEncrypted: isEncrypted, ordinal: ordinal)
    }
}

/// A libarchive read handle on a local file. Not thread safe; one owner at a time.
final class LibArchiveReader {
    private let handle: OpaquePointer
    private let archiveName: String
    private(set) var isFatal = false
    private var opened = false

    /// nil when libarchive recognises no format in the file.
    init?(url: URL, raw: Bool) throws {
        guard let handle = archive_read_new() else { throw ArchiveError.damaged("Out of memory", archive: url.lastPathComponent) }
        self.handle = handle
        archiveName = url.lastPathComponent
        archive_read_support_filter_all(handle)
        archive_read_support_format_tar(handle)
        archive_read_support_format_gnutar(handle)
        archive_read_support_format_zip_seekable(handle)
        archive_read_support_format_cpio(handle)
        archive_read_support_format_iso9660(handle)
        archive_read_support_format_xar(handle)
        archive_read_support_format_cab(handle)
        archive_read_support_format_lha(handle)
        archive_read_support_format_ar(handle)
        if raw { archive_read_support_format_raw(handle) }
        UTF8Locale.use()
        guard archive_read_open_filename(handle, url.path, 1 << 16) == ARCHIVE_OK else {
            let message = Self.message(handle)
            let errno = archive_errno(handle)
            if errno == ENOENT || errno == EACCES || errno == EPERM {
                throw ArchiveError.damaged(message, archive: url.lastPathComponent)
            }
            return nil // "Unrecognized archive format" and friends
        }
        opened = true
    }

    deinit { archive_read_free(handle) }

    var isRaw: Bool { archive_format(handle) == ARCHIVE_FORMAT_RAW }
    var compressedBytesRead: Int64 { archive_filter_bytes(handle, -1) }

    /// The next header, or nil at the end of the archive.
    func nextHeader() throws -> LibArchiveHeader? {
        UTF8Locale.use()
        var entry: OpaquePointer?
        let r = archive_read_next_header(handle, &entry)
        if r == ARCHIVE_EOF { return nil }
        if r == ARCHIVE_FATAL || r == ARCHIVE_FAILED || entry == nil {
            isFatal = true
            throw ArchiveError.damaged(Self.message(handle), archive: archiveName)
        }
        let raw = Self.string(archive_entry_pathname_utf8(entry)) ?? Self.string(archive_entry_pathname(entry)) ?? ""
        let hardlink = Self.string(archive_entry_hardlink_utf8(entry)) ?? Self.string(archive_entry_hardlink(entry))
        return LibArchiveHeader(
            path: VFSPath.local(raw).path,
            type: UInt32(archive_entry_filetype(entry)),
            size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            modified: archive_entry_mtime_is_set(entry) != 0
                ? timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: archive_entry_mtime_nsec(entry)) : nil,
            permissions: UInt16(archive_entry_perm(entry) & 0o7777),
            symlink: Self.string(archive_entry_symlink_utf8(entry)) ?? Self.string(archive_entry_symlink(entry)),
            hardlink: hardlink.map { VFSPath.local($0).path },
            isEncrypted: archive_entry_is_data_encrypted(entry) != 0
        )
    }

    /// Reads data of the current entry. Returns 0 at its end.
    func readData(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let n = archive_read_data(handle, buffer, count)
        if n < 0 {
            if n == ARCHIVE_FATAL { isFatal = true }
            let message = Self.message(handle)
            if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("encrypt") {
                throw ArchiveError.encrypted(entry: "Entry")
            }
            throw ArchiveError.damaged(message, archive: archiveName)
        }
        return n
    }

    func readData(into buffer: inout [UInt8], limit: Int? = nil) throws -> Int {
        let count = min(limit ?? buffer.count, buffer.count)
        return try buffer.withUnsafeMutableBytes { try readData(into: $0.baseAddress!, count: count) }
    }

    private static func message(_ handle: OpaquePointer) -> String {
        string(archive_error_string(handle)) ?? "Unknown archive error"
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}

/// libarchive converts names through the C locale of the calling thread; the default "C" locale
/// is ASCII only, so non-ASCII names would fail. Names without a charset flag are then read as
/// UTF-8, which is what macOS tools write. Only LC_CTYPE of the calling thread changes.
enum UTF8Locale {
    nonisolated(unsafe) private static let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)

    static func use() {
        if let locale { uselocale(locale) }
    }
}
