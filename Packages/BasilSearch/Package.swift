// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilSearch",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilSearch", targets: ["BasilSearch"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
    ],
    targets: [
        .target(
            name: "BasilSearch",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
            ]
        ),
        .testTarget(name: "BasilSearchTests", dependencies: ["BasilSearch"]),
    ]
)
