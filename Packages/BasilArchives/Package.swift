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
        .package(path: "../../Vendor/libarchive"),
        // Tests only: extraction through the copy engine. The library does not depend on it.
        .package(path: "../BasilOperations"),
    ],
    targets: [
        .target(
            name: "BasilArchives",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "CArchive", package: "libarchive"),
            ]
        ),
        .testTarget(name: "BasilArchivesTests", dependencies: [
            "BasilArchives",
            .product(name: "BasilOperations", package: "BasilOperations"),
        ]),
    ]
)
