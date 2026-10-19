// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiskAtlas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskAtlasCore", targets: ["DiskAtlasCore"]),
        .executable(name: "disk-atlas-scan", targets: ["disk-atlas-scan"]),
    ],
    targets: [
        .executableTarget(name: "disk-atlas-scan", dependencies: ["DiskAtlasCore"]),
        .target(name: "DiskAtlasCore", resources: [.process("Resources")]),
        .testTarget(
            name: "DiskAtlasCoreTests",
            dependencies: ["DiskAtlasCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
