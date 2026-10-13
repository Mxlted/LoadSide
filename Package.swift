// swift-tools-version: 6.0
import PackageDescription

#if !os(macOS) || !arch(arm64)
    #error("LoadSide requires a native Apple Silicon Mac. Intel Macs and Rosetta build sessions are unsupported.")
#endif

let package = Package(
    name: "LoadSide",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoadSideCore", targets: ["LoadSideCore"]),
        .executable(name: "LoadSideApp", targets: ["LoadSideApp"]),
        .executable(name: "loadside", targets: ["LoadSideCLI"])
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "CFileKeychain", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "LoadSideCore", dependencies: ["CArchive", "CFileKeychain"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "LoadSideApp", dependencies: ["LoadSideCore"]),
        .executableTarget(name: "LoadSideCLI", dependencies: ["LoadSideCore"]),
        .testTarget(name: "LoadSideCoreTests", dependencies: ["LoadSideCore"]),
        .testTarget(name: "LoadSideAppTests", dependencies: ["LoadSideApp"]),
        .testTarget(name: "LoadSideCLITests", dependencies: ["LoadSideCLI"])
    ]
)
