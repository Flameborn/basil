import BLAKE3
import CryptoKit
import Foundation
import XXHash
import zlib

/// Checksum algorithms for checksum files, like Total Commander's "Create checksum files".
public enum ChecksumAlgorithm: String, CaseIterable, Codable, Sendable {
    case crc32, md5, sha1, sha256, sha384, sha512, sha3_256, sha3_512, blake3, xxh3, xxh128

    /// For menus and speech: "SHA-256".
    public var title: String {
        switch self {
        case .crc32: "CRC32 (SFV)"
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha384: "SHA-384"
        case .sha512: "SHA-512"
        case .sha3_256: "SHA3-256"
        case .sha3_512: "SHA3-512"
        case .blake3: "BLAKE3"
        case .xxh3: "XXH3"
        case .xxh128: "XXH128"
        }
    }

    /// The checksum file's extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .crc32: "sfv"
        case .md5: "md5"
        case .sha1: "sha"
        case .sha256: "sha256"
        case .sha384: "sha384"
        case .sha512: "sha512"
        case .sha3_256: "sha3-256"
        case .sha3_512: "sha3-512"
        case .blake3: "blake3"
        case .xxh3: "xxh3"
        case .xxh128: "xxh128"
        }
    }

    /// Number of hex digits in a digest.
    public var hexLength: Int {
        switch self {
        case .crc32: 8
        case .xxh3: 16
        case .md5, .xxh128: 32
        case .sha1: 40
        case .sha256, .sha3_256, .blake3: 64
        case .sha384: 96
        case .sha512, .sha3_512: 128
        }
    }

    /// The tag of BSD-style lines ("SHA256 (name) = ..."), as written by shasum, b3sum and xxhsum.
    var bsdTag: String {
        switch self {
        case .crc32: "CRC32"
        case .md5: "MD5"
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        case .sha3_256: "SHA3-256"
        case .sha3_512: "SHA3-512"
        case .blake3: "BLAKE3"
        case .xxh3: "XXH3"
        case .xxh128: "XXH128"
        }
    }

    /// The algorithm a checksum file's extension names ("SHA256SUMS" style names are not recognised).
    public init?(fileExtension ext: String) {
        let ext = ext.lowercased()
        if let match = Self.allCases.first(where: { $0.fileExtension == ext }) {
            self = match
            return
        }
        switch ext {
        case "sha1": self = .sha1
        case "b3": self = .blake3
        case "crc", "crc32": self = .crc32
        default: return nil
        }
    }

    /// File names Basil treats as checksum files (Verify Checksums).
    public static func isChecksumFile(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return ChecksumAlgorithm(fileExtension: String(name[name.index(after: dot)...])) != nil
    }

    public func makeHasher() -> ChecksumHasher { ChecksumHasher(self) }
}

/// An incremental hasher for any `ChecksumAlgorithm`. Not thread-safe; use one per file.
public final class ChecksumHasher {
    private enum State {
        case crc32(UInt)
        case md5(Insecure.MD5)
        case sha1(Insecure.SHA1)
        case sha256(SHA256)
        case sha384(SHA384)
        case sha512(SHA512)
        case sha3_256(SHA3_256)
        case sha3_512(SHA3_512)
        case blake3(BLAKE3Box)
        case xxh(XXH3Hasher)
    }

    /// BLAKE3Hasher is non-copyable; boxed so it can sit in the enum.
    private final class BLAKE3Box {
        var hasher = BLAKE3Hasher()
    }

    public let algorithm: ChecksumAlgorithm
    private var state: State

    public init(_ algorithm: ChecksumAlgorithm) {
        self.algorithm = algorithm
        state = switch algorithm {
        case .crc32: .crc32(zlib.crc32(0, nil, 0))
        case .md5: .md5(Insecure.MD5())
        case .sha1: .sha1(Insecure.SHA1())
        case .sha256: .sha256(SHA256())
        case .sha384: .sha384(SHA384())
        case .sha512: .sha512(SHA512())
        case .sha3_256: .sha3_256(SHA3_256())
        case .sha3_512: .sha3_512(SHA3_512())
        case .blake3: .blake3(BLAKE3Box())
        case .xxh3: .xxh(XXH3Hasher(.bits64))
        case .xxh128: .xxh(XXH3Hasher(.bits128))
        }
    }

    public func update(_ buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        switch state {
        case .crc32(let crc):
            // zlib takes a 32-bit length: feed large buffers in parts.
            var crc = crc
            var offset = 0
            while offset < buffer.count {
                let n = min(buffer.count - offset, Int(UInt32.max))
                crc = zlib.crc32(crc, buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), UInt32(n))
                offset += n
            }
            state = .crc32(crc)
        case .md5(var h): h.update(bufferPointer: buffer); state = .md5(h)
        case .sha1(var h): h.update(bufferPointer: buffer); state = .sha1(h)
        case .sha256(var h): h.update(bufferPointer: buffer); state = .sha256(h)
        case .sha384(var h): h.update(bufferPointer: buffer); state = .sha384(h)
        case .sha512(var h): h.update(bufferPointer: buffer); state = .sha512(h)
        case .sha3_256(var h): h.update(bufferPointer: buffer); state = .sha3_256(h)
        case .sha3_512(var h): h.update(bufferPointer: buffer); state = .sha3_512(h)
        case .blake3(let box): box.hasher.update(buffer)
        case .xxh(let h): h.update(buffer)
        }
    }

    public func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    /// Lowercase hex digest. Call once.
    public func finalize() -> String {
        func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        switch state {
        case .crc32(let crc): return String(format: "%08x", UInt32(truncatingIfNeeded: crc))
        case .md5(let h): return hex(h.finalize())
        case .sha1(let h): return hex(h.finalize())
        case .sha256(let h): return hex(h.finalize())
        case .sha384(let h): return hex(h.finalize())
        case .sha512(let h): return hex(h.finalize())
        case .sha3_256(let h): return hex(h.finalize())
        case .sha3_512(let h): return hex(h.finalize())
        case .blake3(let box):
            var done = BLAKE3Hasher()
            swap(&done, &box.hasher)
            return done.finalize().description
        case .xxh(let h): return h.hexDigest()
        }
    }
}

/// Reading and writing checksum files.
///
/// Written: SFV is `name HASH` (upper case, `;` comments); every other algorithm uses the
/// md5sum/sha256sum/b3sum format `hash  name` (two spaces), XXH3 lines carry xxhsum's `XXH3_`
/// prefix. Names are relative to the checksum file's folder with `/` between folders.
/// Read: those, `hash *name` (binary mode), BSD lines `SHA256 (name) = hash`, and comments.
public enum ChecksumFile {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let hash: String
        public init(name: String, hash: String) {
            self.name = name
            self.hash = hash
        }
    }

    public static func line(for entry: Entry, algorithm: ChecksumAlgorithm) -> String {
        switch algorithm {
        case .crc32: "\(entry.name) \(entry.hash.uppercased())"
        case .xxh3: "XXH3_\(entry.hash)  \(entry.name)"
        default: "\(entry.hash)  \(entry.name)"
        }
    }

    public static func contents(_ entries: [Entry], algorithm: ChecksumAlgorithm) -> String {
        var text = algorithm == .crc32 ? "; Generated by Basil\n" : ""
        for entry in entries { text += line(for: entry, algorithm: algorithm) + "\n" }
        return text
    }

    /// Parses a checksum file. `algorithm` comes from the file's extension when known; otherwise
    /// it is taken from BSD tags or the length of the first hash.
    public static func parse(_ text: String, algorithm known: ChecksumAlgorithm?) -> (algorithm: ChecksumAlgorithm?, entries: [Entry]) {
        var algorithm = known
        var entries: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if let bsd = parseBSD(line) {
                if algorithm == nil { algorithm = bsd.algorithm }
                entries.append(bsd.entry)
                continue
            }
            if algorithm == .crc32 || (algorithm == nil && isSFV(line)) {
                // "name HASH": the hash is the last word, names may contain spaces.
                guard let space = line.lastIndex(of: " ") else { continue }
                let hash = String(line[line.index(after: space)...])
                guard hash.count == 8, isHex(hash) else { continue }
                algorithm = algorithm ?? .crc32
                entries.append(Entry(name: String(line[..<space]).trimmingCharacters(in: .whitespaces),
                                     hash: hash.lowercased()))
                continue
            }
            // "hash  name" or "hash *name", optionally "XXH3_hash".
            guard let space = line.firstIndex(of: " ") else { continue }
            var hash = String(line[..<space])
            if hash.hasPrefix("XXH3_") {
                hash.removeFirst(5)
                if algorithm == nil { algorithm = .xxh3 }
            }
            var name = line[line.index(after: space)...]
            if name.first == " " || name.first == "*" { name = name.dropFirst() }
            guard isHex(hash), !name.isEmpty else { continue }
            if algorithm == nil { algorithm = guessed(fromLength: hash.count) }
            entries.append(Entry(name: String(name), hash: hash.lowercased()))
        }
        return (algorithm, entries)
    }

    private static func parseBSD(_ line: String) -> (algorithm: ChecksumAlgorithm?, entry: Entry)? {
        guard let open = line.firstIndex(of: "("), let close = line.range(of: ") = ", options: .backwards),
              open < close.lowerBound else { return nil }
        let tag = line[..<open].trimmingCharacters(in: .whitespaces).uppercased()
        let hash = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isHex(hash) else { return nil }
        let name = String(line[line.index(after: open)..<close.lowerBound])
        let algorithm = ChecksumAlgorithm.allCases.first { $0.bsdTag == tag.replacingOccurrences(of: "SHA-", with: "SHA") }
        return (algorithm, Entry(name: name, hash: hash.lowercased()))
    }

    private static func isSFV(_ line: String) -> Bool {
        guard let space = line.lastIndex(of: " ") else { return false }
        let hash = line[line.index(after: space)...]
        return hash.count == 8 && isHex(String(hash)) && !isHex(String(line[..<space]).trimmingCharacters(in: .whitespaces))
    }

    private static func guessed(fromLength n: Int) -> ChecksumAlgorithm? {
        switch n {
        case 8: .crc32
        case 16: .xxh3
        case 32: .md5
        case 40: .sha1
        case 64: .sha256
        case 96: .sha384
        case 128: .sha512
        default: nil
        }
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isHexDigit)
    }
}
