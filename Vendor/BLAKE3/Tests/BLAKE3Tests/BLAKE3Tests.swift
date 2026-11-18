import BLAKE3
import Testing

struct BLAKE3Tests {
    // Official test vectors (test_vectors.json): input byte i is i % 251.
    private func input(_ length: Int) -> [UInt8] { (0..<length).map { UInt8($0 % 251) } }

    @Test func emptyInput() {
        #expect(BLAKE3.hash([UInt8]()).description == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    @Test func oneByte() {
        #expect(BLAKE3.hash(input(1)).description == "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213")
    }

    @Test func multiChunkInput() {
        // 102400 bytes exercises the SIMD (NEON) path with many 1 KiB chunks.
        #expect(BLAKE3.hash(input(102400)).description.hasPrefix("bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"))
    }

    @Test func incrementalMatchesOneShot() {
        let data = input(70000)
        var hasher = BLAKE3Hasher()
        data.withUnsafeBytes { raw in
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<1000]))
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[1000...]))
        }
        #expect(hasher.finalize() == BLAKE3.hash(data))
    }
}
