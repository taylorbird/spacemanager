// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update for the installed (live) build. build-app.sh embeds and
        // re-signs Sparkle.framework; dev builds carry no feed URL.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(name: "SpaceManager",
                          dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/SpaceManager",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath",
                                                         "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SpaceManagerTests",
                    dependencies: ["SpaceManager"],
                    path: "Tests/SpaceManagerTests")
    ]
)
