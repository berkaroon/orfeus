// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MixerModel",
    platforms: [.macOS("14.2")],
    products: [.library(name: "MixerModel", targets: ["MixerModel"])],
    dependencies: [.package(path: "../AudioCore")],
    targets: [
        .target(name: "MixerModel", dependencies: ["AudioCore"]),
        .testTarget(name: "MixerModelTests", dependencies: ["MixerModel", "AudioCore"])
    ]
)
