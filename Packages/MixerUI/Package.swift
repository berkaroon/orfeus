// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MixerUI",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [.library(name: "MixerUI", targets: ["MixerUI"])],
    dependencies: [.package(path: "../MixerModel")],
    targets: [.target(
        name: "MixerUI",
        dependencies: ["MixerModel"],
        resources: [.process("Resources")]
    )]
)
