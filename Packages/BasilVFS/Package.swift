// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilVFS",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilVFS", targets: ["BasilVFS"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
    ],
    targets: [
        .target(
            name: "BasilVFS",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
            ]
        ),
        .testTarget(name: "BasilVFSTests", dependencies: ["BasilVFS"]),
    ]
)
