// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilGit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilGit", targets: ["BasilGit"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
        .package(path: "../BasilOperations"),
    ],
    targets: [
        .target(
            name: "BasilGit",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BasilOperations", package: "BasilOperations"),
            ]
        ),
        .testTarget(name: "BasilGitTests", dependencies: [
            "BasilGit",
            .product(name: "BasilVFS", package: "BasilVFS"),
            .product(name: "BasilOperations", package: "BasilOperations"),
        ]),
    ]
)
