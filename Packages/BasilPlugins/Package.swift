// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasilPlugins",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BasilPlugins", targets: ["BasilPlugins"]),
    ],
    dependencies: [
        .package(path: "../BasilCore"),
        .package(path: "../BasilVFS"),
    ],
    targets: [
        .target(
            name: "BasilPlugins",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
            ]
        ),
        .testTarget(name: "BasilPluginsTests", dependencies: ["BasilPlugins"]),
    ]
)
