// swift-tools-version: 6.0
// Official BLAKE3 C implementation (portable + NEON), vendored unmodified from
// https://github.com/BLAKE3-team/BLAKE3 tag 1.8.7 (commit f3149ec5bb5449af877ba20377a11008ff499fa2).
// See VERSION. The x86 SIMD variants are not included; x86_64 builds use the portable code.
import PackageDescription

let package = Package(
    name: "BLAKE3",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BLAKE3", targets: ["BLAKE3"]),
    ],
    targets: [
        .target(
            name: "CBLAKE3",
            exclude: ["blake3_neon.inc"],
            cSettings: [
                .define("BLAKE3_NO_SSE2"),
                .define("BLAKE3_NO_SSE41"),
                .define("BLAKE3_NO_AVX2"),
                .define("BLAKE3_NO_AVX512"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        .target(name: "BLAKE3", dependencies: ["CBLAKE3"]),
        .testTarget(name: "BLAKE3Tests", dependencies: ["BLAKE3"]),
    ]
)
