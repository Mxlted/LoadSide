// swift-tools-version: 6.0
import PackageDescription

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
        .target(name: "LoadSideCore", dependencies: ["CArchive"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "LoadSideApp", dependencies: ["LoadSideCore"]),
        .executableTarget(name: "LoadSideCLI", dependencies: ["LoadSideCore"]),
        .testTarget(name: "LoadSideCoreTests", dependencies: ["LoadSideCore"]),
        .testTarget(name: "LoadSideAppTests", dependencies: ["LoadSideApp"]),
        .testTarget(name: "LoadSideCLITests", dependencies: ["LoadSideCLI"])
    ]
)
