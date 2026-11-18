// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilCore", targets: ["BasilCore"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "BasilCore",
            dependencies: [
            ]
        ),
        .testTarget(name: "BasilCoreTests", dependencies: ["BasilCore"]),
    ]
)
