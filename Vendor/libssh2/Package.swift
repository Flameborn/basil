// swift-tools-version: 6.0
// libssh2 1.11.1 with OpenSSL 3.5.9 (LTS) as its crypto backend, both vendored unmodified.
// build.sh compiles them into build/LibSSH2.xcframework (one static library); run it once
// after cloning, before SwiftPM or Xcode resolve packages (scripts/bootstrap.sh). See VERSION.
// CBasilTLS (TLS/, ours) is a small C API over libssl for the FTPS client.
import PackageDescription

let package = Package(
    name: "LibSSH2",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CLibSSH2", targets: ["CLibSSH2"]),
        .library(name: "CBasilTLS", targets: ["CBasilTLS"]),
    ],
    targets: [
        .binaryTarget(name: "CLibSSH2", path: "build/LibSSH2.xcframework"),
        .target(
            name: "CBasilTLS",
            dependencies: ["CLibSSH2"],
            path: "TLS",
            cSettings: [.headerSearchPath("../build/openssl/include")]
        ),
        .testTarget(name: "LibSSH2Tests", dependencies: ["CLibSSH2", "CBasilTLS"]),
    ]
)
