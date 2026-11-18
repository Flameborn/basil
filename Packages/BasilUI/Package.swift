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
    ],
    targets: [
        .target(
            name: "BasilUI",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BasilOperations", package: "BasilOperations"),
                .product(name: "BasilIntegrations", package: "BasilIntegrations"),
            ]
        ),
        .testTarget(name: "BasilUITests", dependencies: ["BasilUI"]),
    ]
)
