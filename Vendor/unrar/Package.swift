// swift-tools-version: 6.0
// The official UnRAR library (the dll.hpp API), built from vendored unmodified upstream sources
// in Sources/CUnRAR/unrar. See VERSION. Only Package.swift, Sources/CUnRAR/include,
// Sources/CUnRAR/BasilErrors.cpp (UnRAR's error state per thread), Tests and VERSION are ours.
// The source list is the makefile's "lib" target (OBJECTS plus LIB_OBJ); the other .cpp files
// are included by those and must not be compiled on their own.
import PackageDescription

let objects = [
    "rar", "strlist", "strfn", "pathfn", "smallfn", "global", "file", "filefn", "filcreat",
    "archive", "arcread", "unicode", "system", "crypt", "crc", "rawread", "encname",
    "resource", "match", "timefn", "rdwrfn", "consio", "options", "errhnd", "rarvm", "secpassword",
    "rijndael", "getbits", "sha1", "sha256", "blake2s", "hash", "extinfo", "extract", "volume",
    "list", "find", "unpack", "headers", "threadpool", "rs16", "cmddata", "ui", "largepage",
    "filestr", "scantree", "dll", "qopen",
]

let package = Package(
    name: "unrar",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CUnRAR", targets: ["CUnRAR"]),
    ],
    targets: [
        .target(
            name: "CUnRAR",
            sources: objects.map { "unrar/\($0).cpp" } + ["BasilErrors.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("RARDLL"),
                // One error state per thread instead of the global one (see BasilErrors.cpp).
                .define("ErrHandler", to: "(*BasilUnRARErrorHandler())"),
                .define("RAR_SMP"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .unsafeFlags(["-O2", "-w"]),
            ]
        ),
        .testTarget(name: "CUnRARTests", dependencies: ["CUnRAR"]),
    ],
    cxxLanguageStandard: .cxx17
)
