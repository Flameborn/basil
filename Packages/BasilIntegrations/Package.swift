// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilIntegrations",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilIntegrations", targets: ["BasilIntegrations"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
    ],
    targets: [
        .target(
            name: "BasilIntegrations",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
            ]
        ),
        .testTarget(name: "BasilIntegrationsTests", dependencies: ["BasilIntegrations"]),
    ]
)
