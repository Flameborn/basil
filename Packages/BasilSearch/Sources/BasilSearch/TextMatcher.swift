import BasilVFS
import Foundation

/// Finds text inside a file, read in chunks through its provider. Literal text (case-sensitive,
/// or ASCII without case) is searched as bytes in each encoding. Regular expressions, whole words
/// and non-ASCII text without case are searched in the decoded text of each chunk; a match longer
/// than `decodedOverlap` that spans two chunks is not found.
public struct TextMatcher: Sendable {
    public enum MatcherError: Error, Equatable, LocalizedError {
        case invalidRegex(String)
        public var errorDescription: String? {
            switch self {
            case .invalidRegex(let text): "\"\(text)\" is not a valid regular expression"
            }
        }
    }

    enum Encoding: Sendable, CaseIterable {
        case utf8, utf16LE, utf16BE, windows1252
    }

    private enum Mode: @unchecked Sendable {
        /// Byte patterns to find; `fold` lowers ASCII letters in the data first (patterns are lowered).
        case bytes([[UInt8]], fold: Bool)
        /// NSRegularExpression is immutable and thread-safe.
        case decoded([Encoding], NSRegularExpression)
    }

    private let mode: Mode
    let overlap: Int
    let notContaining: Bool
    static let chunkSize = 1 << 20
    static let decodedOverlap = 4096

    public init(_ query: TextQuery) throws {
        notContaining = query.notContaining
        let encodings: [Encoding] = switch query.encodings {
        case .all: Encoding.allCases
        case .utf8: [.utf8]
        case .utf16: [.utf16LE, .utf16BE]
        case .windows1252: [.windows1252]
        }
        let isASCII = query.text.unicodeScalars.allSatisfy(\.isASCII)
        if !query.regex, !query.wholeWords, query.caseSensitive || isASCII {
            let text = query.caseSensitive ? query.text : query.text.lowercased()
            var patterns: [[UInt8]] = []
            for encoding in encodings {
                guard var bytes = Self.encode(text, encoding), !bytes.isEmpty else { continue }
                if !query.caseSensitive { bytes = bytes.map(Self.lowerASCII) }
                if !patterns.contains(bytes) { patterns.append(bytes) }
            }
            mode = .bytes(patterns, fold: !query.caseSensitive)
            overlap = max(0, (patterns.map(\.count).max() ?? 1) - 1)
        } else {
            var pattern = query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
            if query.wholeWords { pattern = "\\b(?:" + pattern + ")\\b" }
            var options: NSRegularExpression.Options = []
            if !query.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                throw MatcherError.invalidRegex(query.text)
            }
            mode = .decoded(encodings, regex)
            overlap = Self.decodedOverlap
        }
    }

    /// Whether the file matches: contains the text, or does not contain it for a "not containing" search.
    public func matches(_ file: any ReadableFile) async throws -> Bool {
        try await contains(file) != notContaining
    }

    /// Reads `file` from the start until the text is found or the file ends.
    public func contains(_ file: any ReadableFile) async throws -> Bool {
        var offset: Int64 = 0
        var buffer: [UInt8] = []
        var bufferStart: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await file.read(at: offset, count: Self.chunkSize)
            if data.isEmpty { return false }
            buffer.append(contentsOf: data)
            offset += Int64(data.count)
            if found(in: buffer, startingAt: bufferStart) { return true }
            // Keep the last bytes: a match may start in this chunk and end in the next.
            let keep = min(overlap, buffer.count)
            bufferStart = offset - Int64(keep)
            buffer.removeFirst(buffer.count - keep)
        }
    }

    /// Searches one buffer; `start` is its offset in the file (UTF-16 is read at even offsets).
    func found(in buffer: [UInt8], startingAt start: Int64) -> Bool {
        switch mode {
        case .bytes(let patterns, let fold):
            let hay = fold ? buffer.map(Self.lowerASCII) : buffer
            return patterns.contains { Self.find($0, in: hay) }
        case .decoded(let encodings, let regex):
            for encoding in encodings {
                let text = Self.decode(buffer, encoding, evenStart: start % 2 == 0)
                if regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                    return true
                }
            }
            return false
        }
    }

    // MARK: Bytes

    static func lowerASCII(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= hay.count else { return needle.isEmpty }
        return hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }

    static func encode(_ text: String, _ encoding: Encoding) -> [UInt8]? {
        switch encoding {
        case .utf8: return Array(text.utf8)
        case .utf16LE: return text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        case .utf16BE: return text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        case .windows1252:
            var bytes: [UInt8] = []
            for scalar in text.unicodeScalars {
                guard let byte = Windows1252.byte(for: scalar) else { return nil }
                bytes.append(byte)
            }
            return bytes
        }
    }

    static func decode(_ bytes: [UInt8], _ encoding: Encoding, evenStart: Bool) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .utf16LE, .utf16BE:
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = evenStart ? 0 : 1
            while i + 1 < bytes.count {
                let (a, b) = (UInt16(bytes[i]), UInt16(bytes[i + 1]))
                units.append(encoding == .utf16LE ? a | b << 8 : a << 8 | b)
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case .windows1252:
            var scalars = String.UnicodeScalarView()
            for byte in bytes { scalars.append(Windows1252.scalar(for: byte)) }
            return String(scalars)
        }
    }
}

/// Windows-1252: Latin-1 with printable characters in 0x80-0x9F (five codes there are unused and
/// read as the C1 control of the same number, like Latin-1).
enum Windows1252 {
    static let high: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    static func scalar(for byte: UInt8) -> Unicode.Scalar {
        if byte >= 0x80, byte <= 0x9F { return Unicode.Scalar(high[Int(byte - 0x80)])! }
        return Unicode.Scalar(byte)
    }

    static func byte(for scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if let index = high.firstIndex(of: value) { return UInt8(0x80 + index) }
        if value < 0x80 || (value >= 0xA0 && value <= 0xFF) { return UInt8(value) }
        return nil
    }
}
