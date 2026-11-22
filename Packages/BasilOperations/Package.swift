// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilOperations",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilOperations", targets: ["BasilOperations"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
        .package(path: "../../Vendor/BLAKE3"),
        .package(path: "../../Vendor/xxHash"),
    ],
    targets: [
        .target(
            name: "BasilOperations",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BLAKE3", package: "BLAKE3"),
                .product(name: "XXHash", package: "xxHash"),
            ]
        ),
        .testTarget(name: "BasilOperationsTests", dependencies: ["BasilOperations"]),
    ]
)
