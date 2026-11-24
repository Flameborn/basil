// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilUI",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilUI", targets: ["BasilUI"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
        .package(path: "../BasilOperations"),
        .package(path: "../BasilIntegrations"),
        .package(path: "../BasilGit"),
        .package(path: "../BasilSearch"),
    ],
    targets: [
        .target(
            name: "BasilUI",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BasilOperations", package: "BasilOperations"),
                .product(name: "BasilIntegrations", package: "BasilIntegrations"),
                .product(name: "BasilGit", package: "BasilGit"),
                .product(name: "BasilSearch", package: "BasilSearch"),
            ]
        ),
        .testTarget(name: "BasilUITests", dependencies: ["BasilUI"]),
    ]
)
