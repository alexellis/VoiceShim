// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceShim",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "voice-shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoiceShim",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
