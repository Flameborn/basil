// swift-tools-version: 6.0
// LuaJIT 2.1 (rolling release, see VERSION), vendored unmodified. build.sh compiles it into
// build/LuaJIT.xcframework; run it once after cloning, before SwiftPM or Xcode resolve
// packages (scripts/bootstrap.sh). Plugin APIs are written against Lua 5.1 semantics.
import PackageDescription

let package = Package(
    name: "LuaJIT",
    platforms: [.macOS("27.0")],
    products: [.library(name: "CLuaJIT", targets: ["CLuaJIT"])],
    targets: [
        .binaryTarget(name: "CLuaJIT", path: "build/LuaJIT.xcframework"),
        .testTarget(name: "LuaJITTests", dependencies: ["CLuaJIT"]),
    ]
)
