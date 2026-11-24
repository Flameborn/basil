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
    ],
    targets: [
        .target(
            name: "BasilGit",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
            ]
        ),
        .testTarget(name: "BasilGitTests", dependencies: [
            "BasilGit",
            .product(name: "BasilVFS", package: "BasilVFS"),
        ]),
    ]
)
