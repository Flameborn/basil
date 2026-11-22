import Testing
import XXHash

struct XXHashTests {
    @Test func emptyInputMatchesReferenceValues() {
        #expect(XXH3Hasher(.bits64).hexDigest() == "2d06800538d394c2")
        #expect(XXH3Hasher(.bits128).hexDigest() == "99aa06d3014798d86001c324468d497f")
    }

    @Test func streamingEqualsOneShot() {
        let data = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        for width in [XXH3Hasher.Width.bits64, .bits128] {
            let whole = XXH3Hasher(width)
            data.withUnsafeBytes { whole.update($0) }
            let parts = XXH3Hasher(width)
            for chunk in stride(from: 0, to: data.count, by: 7_777) {
                data[chunk..<min(chunk + 7_777, data.count)].withUnsafeBytes { parts.update($0) }
            }
            #expect(whole.hexDigest() == parts.hexDigest())
        }
    }
}
