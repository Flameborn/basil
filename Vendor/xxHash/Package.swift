// swift-tools-version: 6.0
// Official xxHash C library (XXH3, XXH128), vendored unmodified from
// https://github.com/Cyan4973/xxHash tag v0.8.4. See VERSION. NEON is picked automatically on arm64.
import PackageDescription

let package = Package(
    name: "xxHash",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "XXHash", targets: ["XXHash"]),
    ],
    targets: [
        .target(name: "CXXHash", cSettings: [.unsafeFlags(["-O3"])]),
        .target(name: "XXHash", dependencies: ["CXXHash"]),
        .testTarget(name: "XXHashTests", dependencies: ["XXHash"]),
    ]
)
