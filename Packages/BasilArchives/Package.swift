// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilArchives",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilArchives", targets: ["BasilArchives"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
    ],
    targets: [
        .target(
            name: "BasilArchives",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
            ]
        ),
        .testTarget(name: "BasilArchivesTests", dependencies: ["BasilArchives"]),
    ]
)
