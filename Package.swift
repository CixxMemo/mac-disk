// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiskAtlas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskAtlasCore", targets: ["DiskAtlasCore"]),
    ],
    targets: [
        .target(name: "DiskAtlasCore", resources: [.process("Resources")]),
        .testTarget(
            name: "DiskAtlasCoreTests",
            dependencies: ["DiskAtlasCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
