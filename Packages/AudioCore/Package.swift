// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioCore",
    platforms: [.macOS("14.2")],
    products: [.library(name: "AudioCore", targets: ["AudioCore"])],
    targets: [
        .target(name: "RTAtomic"),
        .target(name: "AudioCore", dependencies: ["RTAtomic"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "RTAtomic"])
    ],
    cLanguageStandard: .c11
)
