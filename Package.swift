// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperType",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperCore", targets: ["WhisperCore"]),
        .executable(name: "WhisperType", targets: ["WhisperType"])
    ],
    targets: [
        .target(name: "WhisperCore"),
        .executableTarget(name: "WhisperType", dependencies: ["WhisperCore"]),
        .testTarget(name: "WhisperCoreTests", dependencies: ["WhisperCore"]),
        .testTarget(name: "WhisperTypeTests", dependencies: ["WhisperType"])
    ],
    swiftLanguageVersions: [.v5]
)
