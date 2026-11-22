// Swift wrapper around the official xxHash C library (XXH3 64-bit and XXH128).

import CXXHash

/// Incremental XXH3 hasher, 64-bit or 128-bit. Not thread-safe; use one per task.
public final class XXH3Hasher {
    public enum Width: Sendable { case bits64, bits128 }

    private let state: OpaquePointer
    public let width: Width

    public init(_ width: Width) {
        self.width = width
        state = XXH3_createState()
        switch width {
        case .bits64: XXH3_64bits_reset(state)
        case .bits128: XXH3_128bits_reset(state)
        }
    }

    deinit { XXH3_freeState(state) }

    public func update(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        switch width {
        case .bits64: XXH3_64bits_update(state, base, buffer.count)
        case .bits128: XXH3_128bits_update(state, base, buffer.count)
        }
    }

    /// The digest in xxhsum's canonical form: lowercase hex, big-endian (XXH128: high half first).
    public func hexDigest() -> String {
        func hex(_ v: UInt64) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: 16 - s.count) + s
        }
        switch width {
        case .bits64: return hex(XXH3_64bits_digest(state))
        case .bits128:
            let h = XXH3_128bits_digest(state)
            return hex(h.high64) + hex(h.low64)
        }
    }
}
