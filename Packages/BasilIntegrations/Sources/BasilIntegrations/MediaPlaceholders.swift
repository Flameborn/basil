import AudioToolbox
import BasilCore
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Multi-Rename placeholders for photos and audio, like Total Commander's plugin fields:
/// [=exif.year] ... [=exif.second] (date taken), [=exif.make], [=exif.model], [=exif.width],
/// [=exif.height]; [=audio.artist], [=audio.title], [=audio.album], [=audio.track] (two digits),
/// [=audio.year], [=audio.genre].
///
/// Photos are read through ImageIO (the properties only, never the pixels), audio through
/// AudioToolbox's file info dictionary (ID3 in MP3, M4A, AIFF, FLAC and whatever else macOS
/// reads). Values are empty for files that are not of that kind, have no such field, or have no
/// local file (`localPath` answers nil: servers other than mounted shares, archives). Nothing is
/// changed in a value: a "/" in an artist's name stays and the preview reports it.
public enum MediaPlaceholders {
    public struct Field: Sendable {
        public let name: String
        public let title: String
    }

    public static let fields: [Field] = [
        Field(name: "exif.year", title: "Photo date taken: year"),
        Field(name: "exif.month", title: "Photo date taken: month"),
        Field(name: "exif.day", title: "Photo date taken: day"),
        Field(name: "exif.hour", title: "Photo date taken: hour"),
        Field(name: "exif.minute", title: "Photo date taken: minute"),
        Field(name: "exif.second", title: "Photo date taken: second"),
        Field(name: "exif.make", title: "Photo camera make"),
        Field(name: "exif.model", title: "Photo camera model"),
        Field(name: "exif.width", title: "Photo width"),
        Field(name: "exif.height", title: "Photo height"),
        Field(name: "audio.artist", title: "Audio artist"),
        Field(name: "audio.title", title: "Audio title"),
        Field(name: "audio.album", title: "Audio album"),
        Field(name: "audio.track", title: "Audio track number"),
        Field(name: "audio.year", title: "Audio year"),
        Field(name: "audio.genre", title: "Audio genre"),
    ]

    /// Registers every field. `localPath` gives the local file of an item's path, or nil.
    public static func register(localPath: @escaping @Sendable (VFSPath) -> String?) {
        for field in fields {
            let name = field.name
            MultiRenamePlaceholders.register(.init(name: name, title: field.title) { input in
                guard let path = localPath(input.item.path) else { return "" }
                return values(of: path)[name] ?? ""
            })
        }
    }

    /// Every field of one file, by name. Cached by path, size and modification date.
    public static func values(of path: String) -> [String: String] {
        var st = Darwin.stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return [:] }
        let key = CacheKey(path: path, size: Int64(st.st_size), modified: st.st_mtimespec.tv_sec,
                           modifiedNanoseconds: st.st_mtimespec.tv_nsec)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let url = URL(fileURLWithPath: path)
        let type = UTType(filenameExtension: url.pathExtension)
        var result: [String: String] = [:]
        if type?.conforms(to: .image) == true {
            result = photo(url)
        } else if type?.conforms(to: .audio) == true {
            result = audio(url)
        }
        cache.withLock { entries in
            if entries.count > 10_000 { entries.removeAll() }
            entries[key] = result
        }
        return result
    }

    struct CacheKey: Hashable {
        let path: String
        let size: Int64
        let modified: Int
        let modifiedNanoseconds: Int
    }

    private static let cache = Mutex<[CacheKey: [String: String]]>([:])

    // MARK: Photos

    static func photo(_ url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any] else { return [:] }
        var result: [String: String] = [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        // "2026:07:14 09:05:33"; the original date first, then when it was digitised, then TIFF's.
        let date = [exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifDateTimeDigitized],
                    tiff[kCGImagePropertyTIFFDateTime]].compactMap { $0 as? String }.first
        if let date, let parts = exifDate(date) {
            for (name, value) in zip(["year", "month", "day", "hour", "minute", "second"], parts) {
                result["exif.\(name)"] = value
            }
        }
        if let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !make.isEmpty { result["exif.make"] = make }
        if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty { result["exif.model"] = model }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // As the photo is seen: orientations 5 to 8 are turned a quarter.
            let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            result["exif.width"] = String(turned ? height : width)
            result["exif.height"] = String(turned ? width : height)
        }
        return result
    }

    /// "2026:07:14 09:05:33" (also with "-" in the date or "T" between) as six strings.
    static func exifDate(_ text: String) -> [String]? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard digits.count >= 6, digits[0].count == 4, digits[0] != "0000" else { return nil }
        return Array(digits.prefix(6)).map { $0.count == 1 ? "0" + $0 : $0 }
    }

    // MARK: Audio

    static func audio(_ url: URL) -> [String: String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [:] }
        defer { AudioFileClose(file) }
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var info: Unmanaged<CFDictionary>?
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let dictionary = info?.takeRetainedValue() as? [String: Any] else { return [:] }
        func text(_ key: String) -> String? {
            let value = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        var result: [String: String] = [:]
        result["audio.artist"] = text(kAFInfoDictionary_Artist)
        result["audio.title"] = text(kAFInfoDictionary_Title)
        result["audio.album"] = text(kAFInfoDictionary_Album)
        result["audio.genre"] = text(kAFInfoDictionary_Genre)
        // "3", "3/12" or "03": the number, two digits at least.
        if let track = text(kAFInfoDictionary_TrackNumber)?.split(separator: "/").first.flatMap({ Int($0) }) {
            result["audio.track"] = track < 10 ? "0\(track)" : String(track)
        }
        // "2019" or a whole date: its year.
        // AudioToolbox reads ID3v2.3's year (TYER) but not ID3v2.4's recording time (TDRC).
        let year = (text(kAFInfoDictionary_Year) ?? text(kAFInfoDictionary_RecordedDate) ?? ID3Date.read(url))?.prefix(4)
        if let year, year.count == 4, year.allSatisfy(\.isNumber) { result["audio.year"] = String(year) }
        return result
    }
}

/// The date frames of an ID3v2.3 or v2.4 tag at the start of a file: TDRC (recording time),
/// TYER, TDOR (original release). Only what AudioToolbox leaves out.
enum ID3Date {
    static func read(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8), [3, 4].contains(header[3]) else { return nil }
        let version = header[3]
        let flags = header[5]
        let size = syncsafe(header[6..<10])
        guard size > 0, size < 16 << 20, var tag = try? handle.read(upToCount: size), tag.count == size else { return nil }
        // Unsynchronisation of the whole tag (v2.3; v2.4 marks it per frame, rare for text).
        if flags & 0x80 != 0, version == 3 { tag = removeUnsync(tag) }
        var bytes = [UInt8](tag)
        var offset = 0
        if flags & 0x40 != 0, bytes.count >= 4 {
            // Extended header: v2.3 gives its size without these 4 bytes, v2.4 with them.
            let extended = version == 4 ? syncsafe(bytes[0..<4]) : Int(bigEndian(bytes[0..<4])) + 4
            offset = extended
        }
        var found: [String: String] = [:]
        while offset + 10 <= bytes.count, bytes[offset] != 0 {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let length = version == 4 ? syncsafe(bytes[offset + 4..<offset + 8]) : Int(bigEndian(bytes[offset + 4..<offset + 8]))
            let start = offset + 10
            guard length > 0, start + length <= bytes.count else { break }
            if ["TDRC", "TYER", "TDOR"].contains(id), let value = text(Array(bytes[start..<start + length])) {
                found[id] = value
            }
            offset = start + length
        }
        return found["TDRC"] ?? found["TYER"] ?? found["TDOR"]
    }

    static func syncsafe(_ b: some Collection<UInt8>) -> Int {
        b.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    static func bigEndian(_ b: some Collection<UInt8>) -> UInt32 {
        b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func removeUnsync(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if previous == 0xFF, byte == 0 { previous = 0; continue }
            out.append(byte)
            previous = byte
        }
        return out
    }

    /// A text frame's first value: encoding byte (Latin-1, UTF-16 with BOM, UTF-16 BE, UTF-8).
    static func text(_ frame: [UInt8]) -> String? {
        guard let encoding = frame.first else { return nil }
        let body = Data(frame.dropFirst())
        let value: String?
        switch encoding {
        case 0: value = String(data: body, encoding: .isoLatin1)
        case 1: value = String(data: body, encoding: .utf16)
        case 2: value = String(data: body, encoding: .utf16BigEndian)
        case 3: value = String(data: body, encoding: .utf8)
        default: value = nil
        }
        let first = value?.split(separator: "\0").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return first?.isEmpty == false ? first : nil
    }
}
