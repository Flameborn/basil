import BasilVFS
import Darwin
import Foundation

/// Converts between extended attributes and AppleDouble data, the format Finder stores in
/// "__MACOSX/._name" zip entries and "._name" tar entries. The system's copyfile does the
/// encoding, through two scratch files.
enum AppleDouble {
    /// Security attributes that describe this Mac, not the file, and are not packed.
    static let excluded: Set<String> = ["com.apple.quarantine", "com.apple.provenance", "com.apple.macl"]

    private static let scratch: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Basil AppleDouble", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// AppleDouble data holding `attributes`, or nil when there is nothing to store.
    static func pack(_ attributes: [FileMetadata.ExtendedAttribute]) -> Data? {
        let kept = attributes.filter { !excluded.contains($0.name) }
        guard !kept.isEmpty else { return nil }
        let id = UUID().uuidString
        let file = scratch.appendingPathComponent(id)
        let double = scratch.appendingPathComponent("._" + id)
        defer {
            unlink(file.path)
            unlink(double.path)
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
        for attr in kept {
            _ = attr.value.withUnsafeBytes { setxattr(file.path, attr.name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        }
        guard copyfile(file.path, double.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_XATTR)) == 0 else { return nil }
        return try? Data(contentsOf: double)
    }

    /// The extended attributes stored in AppleDouble data (empty when it holds none or is damaged).
    static func unpack(_ data: Data) -> [FileMetadata.ExtendedAttribute] {
        let id = UUID().uuidString
        let file = scratch.appendingPathComponent(id)
        let double = scratch.appendingPathComponent("._" + id)
        defer {
            unlink(file.path)
            unlink(double.path)
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              (try? data.write(to: double)) != nil,
              copyfile(double.path, file.path, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR)) == 0
        else { return [] }
        return readAll(file.path).filter { !excluded.contains($0.name) }
    }

    private static func readAll(_ path: String) -> [FileMetadata.ExtendedAttribute] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [] }
        var result: [FileMetadata.ExtendedAttribute] = []
        var start = 0
        for i in 0..<size where names[i] == 0 {
            let name = names[start..<i].withUnsafeBufferPointer { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            start = i + 1
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            if read == length { result.append(.init(name: name, value: value)) }
        }
        return result
    }
}
