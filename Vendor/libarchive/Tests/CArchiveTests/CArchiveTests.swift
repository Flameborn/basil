import CArchive
import Foundation
import Testing

/// Round trip through every filter Basil relies on: write a tar with one entry, read it back.
@Suite struct CArchiveTests {
    @Test func versionMentionsCompressionLibraries() {
        let details = String(cString: archive_version_details())
        #expect(details.contains("libarchive 3.8"))
        for lib in ["zlib", "liblzma", "bz2lib", "liblz4", "libzstd"] {
            #expect(details.contains(lib), "missing \(lib) in \(details)")
        }
    }

    @Test(arguments: [ARCHIVE_FILTER_NONE, ARCHIVE_FILTER_GZIP, ARCHIVE_FILTER_BZIP2,
                      ARCHIVE_FILTER_XZ, ARCHIVE_FILTER_LZ4, ARCHIVE_FILTER_ZSTD])
    func roundTrip(filter: Int32) throws {
        let payload = Array(String(repeating: "Basil archive test. ", count: 5000).utf8)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var used = 0

        let writer = try #require(archive_write_new())
        #expect(archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK)
        #expect(archive_write_add_filter(writer, filter) == ARCHIVE_OK)
        buffer.withUnsafeMutableBytes { raw in
            #expect(archive_write_open_memory(writer, raw.baseAddress, raw.count, &used) == ARCHIVE_OK)
        }
        let entry = archive_entry_new()
        archive_entry_set_pathname(entry, "folder/hello.txt")
        archive_entry_set_size(entry, la_int64_t(payload.count))
        archive_entry_set_filetype(entry, 0o100000) // AE_IFREG, a cast macro Swift does not import
        archive_entry_set_perm(entry, 0o644)
        #expect(archive_write_header(writer, entry) == ARCHIVE_OK)
        #expect(archive_write_data(writer, payload, payload.count) == payload.count)
        archive_entry_free(entry)
        #expect(archive_write_free(writer) == ARCHIVE_OK)
        #expect(used > 0)

        let reader = try #require(archive_read_new())
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        let opened = buffer.withUnsafeBytes { archive_read_open_memory(reader, $0.baseAddress, used) }
        #expect(opened == ARCHIVE_OK)
        var header: OpaquePointer?
        #expect(archive_read_next_header(reader, &header) == ARCHIVE_OK)
        #expect(String(cString: archive_entry_pathname(header)) == "folder/hello.txt")
        var read = [UInt8](repeating: 0, count: payload.count + 10)
        let count = archive_read_data(reader, &read, read.count)
        #expect(count == payload.count)
        #expect(Array(read.prefix(count)) == payload)
        #expect(archive_filter_code(reader, 0) == filter)
        archive_read_free(reader)
    }
}
