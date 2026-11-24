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
        .package(path: "../BasilOperations"),
        .package(path: "../../Vendor/luajit"),
    ],
    targets: [
        .target(
            name: "BasilPlugins",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "BasilOperations", package: "BasilOperations"),
                .product(name: "CLuaJIT", package: "luajit"),
            ]
        ),
        .testTarget(name: "BasilPluginsTests", dependencies: ["BasilPlugins"]),
    ]
)
