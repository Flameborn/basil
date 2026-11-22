import BasilCore
import BasilVFS
import CArchive
import Foundation

/// The formats Basil writes with libarchive, and how each one sets up a write handle.
enum LibArchiveFormats {
    enum Container: Sendable, Equatable {
        case zip, tar, cpio, xar, iso, raw
        case existing(format: Int32)
    }

    enum Filter: Sendable, Equatable { case gzip, bzip2, xz, zstd, lz4 }

    struct Spec: Sendable, Equatable {
        var container: Container
        var filters: [Int32] = []
        var level: PackLevel = .normal
        var storesMacMetadata: Bool { container == .zip || container == .tar || isExistingTar }
        var isZip: Bool {
            if case .existing(let f) = container { return f & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_ZIP }
            return container == .zip
        }
        private var isExistingTar: Bool {
            if case .existing(let f) = container { return f & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_TAR }
            return false
        }
    }

    static let tarLevels: [PackLevel] = [.fast, .normal, .maximum]

    /// Pack dialog order. The id is also the file extension.
    static let all: [(PackFormat, Container, Int32?)] = [
        (PackFormat(id: "zip", name: "ZIP", levels: [.store, .fast, .normal, .maximum], storesMacMetadata: true), .zip, nil),
        (PackFormat(id: "tar.gz", name: "tar.gz (gzip)", storesMacMetadata: true), .tar, ARCHIVE_FILTER_GZIP),
        (PackFormat(id: "tar.xz", name: "tar.xz (xz)", storesMacMetadata: true), .tar, ARCHIVE_FILTER_XZ),
        (PackFormat(id: "tar.zst", name: "tar.zst (Zstandard)", storesMacMetadata: true), .tar, ARCHIVE_FILTER_ZSTD),
        (PackFormat(id: "tar.bz2", name: "tar.bz2 (bzip2)", storesMacMetadata: true), .tar, ARCHIVE_FILTER_BZIP2),
        (PackFormat(id: "tar.lz4", name: "tar.lz4 (LZ4)", storesMacMetadata: true), .tar, ARCHIVE_FILTER_LZ4),
        (PackFormat(id: "tar", name: "tar (no compression)", levels: [], storesMacMetadata: true), .tar, nil),
        (PackFormat(id: "gz", name: "gz (one file, gzip)", singleFile: true), .raw, ARCHIVE_FILTER_GZIP),
        (PackFormat(id: "xz", name: "xz (one file, xz)", singleFile: true), .raw, ARCHIVE_FILTER_XZ),
        (PackFormat(id: "zst", name: "zst (one file, Zstandard)", singleFile: true), .raw, ARCHIVE_FILTER_ZSTD),
        (PackFormat(id: "cpio", name: "cpio", levels: []), .cpio, nil),
        (PackFormat(id: "xar", name: "xar", levels: []), .xar, nil),
        (PackFormat(id: "iso", name: "ISO 9660 disc image", levels: []), .iso, nil),
    ]

    static var packFormats: [PackFormat] { all.map(\.0) }

    static func spec(for options: PackOptions) -> Spec? {
        guard let (_, container, filter) = all.first(where: { $0.0.id == options.format }) else { return nil }
        return Spec(container: container, filters: filter.map { [$0] } ?? [], level: options.level)
    }

    /// Each filter's own number for a level.
    static func level(_ level: PackLevel, filter: Int32) -> Int {
        switch filter {
        case ARCHIVE_FILTER_GZIP, ARCHIVE_FILTER_BZIP2: [.store: 1, .fast: 1, .normal: 6, .maximum: 9, .ultra: 9][level]!
        case ARCHIVE_FILTER_XZ: [.store: 0, .fast: 1, .normal: 6, .maximum: 9, .ultra: 9][level]!
        case ARCHIVE_FILTER_ZSTD: [.store: 1, .fast: 1, .normal: 3, .maximum: 19, .ultra: 19][level]!
        case ARCHIVE_FILTER_LZ4: [.store: 1, .fast: 1, .normal: 3, .maximum: 9, .ultra: 9][level]!
        default: 6
        }
    }

    static func filterName(_ filter: Int32) -> String? {
        switch filter {
        case ARCHIVE_FILTER_GZIP: "gzip"
        case ARCHIVE_FILTER_BZIP2: "bzip2"
        case ARCHIVE_FILTER_XZ: "xz"
        case ARCHIVE_FILTER_ZSTD: "zstd"
        case ARCHIVE_FILTER_LZ4: "lz4"
        default: nil
        }
    }
}

/// A libarchive write handle on a local file. Not thread safe; one owner at a time, and all
/// calls block.
final class LibArchiveWriter {
    private let handle: OpaquePointer
    let spec: LibArchiveFormats.Spec
    private let name: String
    private var closed = false

    init(url: URL, spec: LibArchiveFormats.Spec) throws {
        guard let handle = archive_write_new() else { throw ArchiveError.damaged("Out of memory", archive: url.lastPathComponent) }
        self.handle = handle
        self.spec = spec
        name = url.lastPathComponent
        UTF8Locale.use()
        try check(setFormat())
        for filter in spec.filters {
            try check(archive_write_add_filter(handle, filter))
            if let filterName = LibArchiveFormats.filterName(filter) {
                let level = LibArchiveFormats.level(spec.level, filter: filter)
                try check(archive_write_set_filter_option(handle, filterName, "compression-level", String(level)))
            }
        }
        if spec.isZip {
            if spec.level == .store {
                try check(archive_write_set_format_option(handle, "zip", "compression", "store"))
            } else {
                let level = [PackLevel.fast: 1, .normal: 6, .maximum: 9, .ultra: 9][spec.level] ?? 6
                try check(archive_write_set_format_option(handle, "zip", "compression-level", String(level)))
            }
        }
        // Names are written as UTF-8 and marked so.
        if spec.isZip { _ = archive_write_set_format_option(handle, "zip", "hdrcharset", "UTF-8") }
        try check(archive_write_open_filename(handle, url.path))
    }

    deinit {
        if !closed { archive_write_close(handle) }
        archive_write_free(handle)
    }

    private func setFormat() -> Int32 {
        switch spec.container {
        case .zip: archive_write_set_format_zip(handle)
        case .tar: archive_write_set_format_pax_restricted(handle)
        case .cpio: archive_write_set_format_cpio_newc(handle)
        case .xar: archive_write_set_format_xar(handle)
        case .iso: archive_write_set_format_iso9660(handle)
        case .raw: archive_write_set_format_raw(handle)
        case .existing(let code):
            switch code & ARCHIVE_FORMAT_BASE_MASK {
            case ARCHIVE_FORMAT_ZIP: archive_write_set_format_zip(handle)
            case ARCHIVE_FORMAT_TAR: archive_write_set_format_pax_restricted(handle)
            case ARCHIVE_FORMAT_CPIO: archive_write_set_format_cpio_newc(handle)
            case ARCHIVE_FORMAT_XAR: archive_write_set_format_xar(handle)
            case ARCHIVE_FORMAT_ISO9660: archive_write_set_format_iso9660(handle)
            default: ARCHIVE_FATAL
            }
        }
    }

    private func check(_ r: Int32) throws {
        if r < ARCHIVE_WARN {
            throw ArchiveError.damaged(archive_error_string(handle).map { String(cString: $0) } ?? "Cannot write the archive", archive: name)
        }
    }

    /// Writes one header. `entry` is an archive_entry the caller owns.
    func writeHeader(_ entry: OpaquePointer) throws {
        try check(archive_write_header(handle, entry))
    }

    func write(_ data: UnsafeRawBufferPointer) throws {
        guard let base = data.baseAddress, data.count > 0 else { return }
        var offset = 0
        while offset < data.count {
            let n = archive_write_data(handle, base + offset, data.count - offset)
            if n < 0 { try check(Int32(n)) }
            if n == 0 { throw ArchiveError.damaged("Cannot write the archive", archive: name) }
            offset += n
        }
    }

    func finishEntry() throws {
        try check(archive_write_finish_entry(handle))
    }

    /// Writes a zip "__MACOSX/<folder>/._<name>" entry with AppleDouble data, as Finder does.
    /// Tar formats store the data with the entry itself (`archive_entry_copy_mac_metadata`).
    func writeZipAppleDouble(_ data: Data, for path: String, modified: timespec?) throws {
        let parent = ArchiveIndex.parent(of: path)
        let doublePath = "__MACOSX" + (parent == "/" ? "" : parent) + "/._" + ArchiveIndex.name(of: path)
        let entry = archive_entry_new()
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, doublePath)
        archive_entry_set_filetype(entry, 0o100000)
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_size(entry, la_int64_t(data.count))
        if let modified { archive_entry_set_mtime(entry, modified.tv_sec, modified.tv_nsec) }
        try writeHeader(entry!)
        try data.withUnsafeBytes { try write($0) }
        try finishEntry()
    }

    func close() throws {
        closed = true
        try check(archive_write_close(handle))
    }
}
