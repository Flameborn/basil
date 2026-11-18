// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilSync",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilSync", targets: ["BasilSync"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
        .package(path: "../BasilOperations"),
    ],
    targets: [
        .target(
            name: "BasilSync",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BasilOperations", package: "BasilOperations"),
            ]
        ),
        .testTarget(name: "BasilSyncTests", dependencies: ["BasilSync"]),
    ]
)
