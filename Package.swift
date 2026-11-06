// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppControl",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AppControl", targets: ["AppControl"]),
    ],
    targets: [
        .target(
            name: "AppControl",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AppControlTests",
            dependencies: ["AppControl"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
