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
        // Needs Vendor/libssh2/build.sh to have run (scripts/bootstrap.sh).
        .package(path: "../../Vendor/libssh2"),
        // Tests only: copies to and from SFTP go through the copy engine.
        .package(path: "../BasilOperations"),
    ],
    targets: [
        .target(
            name: "BasilRemote",
            dependencies: [
                .product(name: "BasilCore", package: "BasilCore"),
                .product(name: "BasilVFS", package: "BasilVFS"),
                .product(name: "CLibSSH2", package: "LibSSH2"),
            ]
        ),
        .testTarget(name: "BasilRemoteTests", dependencies: [
            "BasilRemote",
            .product(name: "BasilOperations", package: "BasilOperations"),
        ]),
    ]
)
