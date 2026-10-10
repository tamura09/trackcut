// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackCut",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "TrackCutCore"),
        .executableTarget(
            name: "TrackCut",
            dependencies: ["TrackCutCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "TrackCutCoreTests", dependencies: ["TrackCutCore"]),
        .testTarget(name: "TrackCutTests", dependencies: ["TrackCut", "TrackCutCore"]),
    ],
    swiftLanguageModes: [.v5]
)
