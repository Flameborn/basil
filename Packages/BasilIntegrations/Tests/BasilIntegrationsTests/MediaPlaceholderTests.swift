import BasilCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BasilIntegrations

/// Photo and audio fields for Multi-Rename, read from files made here: a JPEG with EXIF written
/// through ImageIO and an MP3 with an ID3v2.4 tag built by hand (silent MPEG frames).
final class MediaPlaceholderTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func photo(_ name: String, orientation: Int = 1, exif: [CFString: Any], tiff: [CFString: Any]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif,
                                                        kCGImagePropertyTIFFDictionary: tiff,
                                                        kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// ID3v2.4 with UTF-8 text frames, then silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz).
    func song(_ name: String, frames: [(String, String)]) throws -> URL {
        func syncsafe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] }
        var body: [UInt8] = []
        for (id, text) in frames {
            let content = [3] + Array(text.utf8)
            body += Array(id.utf8) + syncsafe(content.count) + [0, 0] + content
        }
        var data = Data(Array("ID3".utf8) + [4, 0, 0] + syncsafe(body.count) + body)
        for _ in 0..<40 { data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 413)) }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func photoFields() throws {
        let url = try photo("p.jpg", orientation: 6,
                            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:07:14 09:05:33"],
                            tiff: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"])
        let values = MediaPlaceholders.values(of: url.path)
        #expect(values["exif.year"] == "2026" && values["exif.month"] == "07" && values["exif.day"] == "14")
        #expect(values["exif.hour"] == "09" && values["exif.minute"] == "05" && values["exif.second"] == "33")
        #expect(values["exif.make"] == "Apple" && values["exif.model"] == "iPhone 17 Pro")
        // Orientation 6 is turned a quarter: 40 by 30 pixels show as 30 wide.
        #expect(values["exif.width"] == "30" && values["exif.height"] == "40")
    }

    @Test func aPhotoWithoutDatesHasOnlyItsSize() throws {
        let url = try photo("plain.jpg", exif: [:], tiff: [:])
        let values = MediaPlaceholders.values(of: url.path)
        #expect(values["exif.year"] == nil && values["exif.model"] == nil)
        #expect(values["exif.width"] == "40" && values["exif.height"] == "30")
    }

    @Test func audioFields() throws {
        let url = try song("s.mp3", frames: [("TPE1", "Sigur Rós"), ("TIT2", "Says"), ("TALB", "Spaces"),
                                             ("TRCK", "3/12"), ("TDRC", "2013-05-01"), ("TCON", "Ambient")])
        let values = MediaPlaceholders.values(of: url.path)
        #expect(values["audio.artist"] == "Sigur Rós")
        #expect(values["audio.title"] == "Says" && values["audio.album"] == "Spaces")
        #expect(values["audio.track"] == "03" && values["audio.year"] == "2013" && values["audio.genre"] == "Ambient")
    }

    @Test func yearsFromVersion3AndOtherEncodings() throws {
        let v3 = try song("v3.mp3", frames: [("TYER", "1999")])
        #expect(MediaPlaceholders.values(of: v3.path)["audio.year"] == "1999")
        // A UTF-16 TDRC with a byte order mark, read by Basil itself.
        var utf16: [UInt8] = [1, 0xFF, 0xFE]
        for unit in "2021-03-04".utf16 { utf16 += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        #expect(ID3Date.text(utf16) == "2021-03-04")
        #expect(ID3Date.text([0] + Array("2001".utf8)) == "2001")
        let none = try song("none.mp3", frames: [("TIT2", "Untitled")])
        #expect(MediaPlaceholders.values(of: none.path)["audio.year"] == nil)
    }

    @Test func otherFilesHaveNoFields() throws {
        let url = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: url)
        #expect(MediaPlaceholders.values(of: url.path).isEmpty)
        // Named like a photo, but not one.
        let fake = folder.appendingPathComponent("fake.jpg")
        try Data("not a jpeg".utf8).write(to: fake)
        #expect(MediaPlaceholders.values(of: fake.path).isEmpty)
        #expect(MediaPlaceholders.values(of: folder.appendingPathComponent("missing.mp3").path).isEmpty)
    }

    @Test func masksUseTheFields() throws {
        let url = try photo("IMG_0001.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2026:07:14 09:05:33"],
                            tiff: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"])
        MediaPlaceholders.register { $0.location == .local ? $0.path : nil }
        var rule = RenameRule()
        rule.nameMask = "[=exif.year]-[=exif.month]-[=exif.day] [=exif.model]"
        let item = FileItem(path: .local(url.path), kind: .file, size: 0, modified: nil)
        #expect(MultiRename.newName(for: RenameInput(item: item, index: 0), rule: rule) == "2026-07-14 iPhone 17 Pro.jpg")
        let away = FileItem(path: VFSPath(location: ProviderLocation(provider: ProviderID("sftp"), instance: "a@b"), path: url.path),
                            kind: .file, size: 0, modified: nil)
        #expect(MultiRename.newName(for: RenameInput(item: away, index: 0), rule: rule) == "-- .jpg")
    }
}
