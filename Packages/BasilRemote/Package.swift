// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilRemote",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilRemote", targets: ["BasilRemote"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
    ],
    targets: [
        .target(
            name: "BasilRemote",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
            ]
        ),
        .testTarget(name: "BasilRemoteTests", dependencies: ["BasilRemote"]),
    ]
)
