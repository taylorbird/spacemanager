// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SpaceManager", path: "Sources/SpaceManager")
    ]
)
