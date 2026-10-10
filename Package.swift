// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackCut",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TrackCutCore"),
        .executableTarget(name: "TrackCut", dependencies: ["TrackCutCore"]),
        .testTarget(name: "TrackCutCoreTests", dependencies: ["TrackCutCore"]),
        .testTarget(name: "TrackCutTests", dependencies: ["TrackCut", "TrackCutCore"]),
    ],
    swiftLanguageModes: [.v5]
)
