// Swift wrapper around the official BLAKE3 C implementation.

import CBLAKE3
import Foundation

/// A 32-byte BLAKE3 digest.
public struct BLAKE3Digest: Hashable, Sendable, CustomStringConvertible {
    public var bytes: (UInt64, UInt64, UInt64, UInt64)

    public static func == (a: Self, b: Self) -> Bool {
        a.bytes.0 == b.bytes.0 && a.bytes.1 == b.bytes.1 && a.bytes.2 == b.bytes.2 && a.bytes.3 == b.bytes.3
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.0); hasher.combine(bytes.1); hasher.combine(bytes.2); hasher.combine(bytes.3)
    }

    /// Lowercase hex.
    public var description: String {
        withUnsafeBytes(of: bytes) { raw in
            raw.map { byte in
                let s = String(byte, radix: 16)
                return s.count == 1 ? "0" + s : s
            }.joined()
        }
    }
}

/// Incremental BLAKE3 hasher. Not thread-safe; use one per task.
public struct BLAKE3Hasher: ~Copyable {
    private var state = blake3_hasher()

    public init() {
        blake3_hasher_init(&state)
    }

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        blake3_hasher_update(&state, base, buffer.count)
    }

    public consuming func finalize() -> BLAKE3Digest {
        var out = BLAKE3Digest(bytes: (0, 0, 0, 0))
        withUnsafeMutableBytes(of: &out.bytes) { raw in
            blake3_hasher_finalize(&state, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(BLAKE3_OUT_LEN))
        }
        return out
    }
}

public enum BLAKE3 {
    /// One-shot hash of a buffer.
    public static func hash(_ buffer: UnsafeRawBufferPointer) -> BLAKE3Digest {
        var hasher = BLAKE3Hasher()
        hasher.update(buffer)
        return hasher.finalize()
    }

    public static func hash<D: ContiguousBytes>(_ data: D) -> BLAKE3Digest {
        data.withUnsafeBytes { hash($0) }
    }
}
