// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DuckAudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DuckAudioCore",
            targets: ["DuckAudioCore"]
        ),
        .executable(
            name: "duck-audio-phase0",
            targets: ["DuckAudioPhase0"]
        ),
        .executable(
            name: "duck-audio-tapmeter",
            targets: ["DuckAudioTapMeter"]
        ),
        .executable(
            name: "duck-audio-duckfactor",
            targets: ["DuckAudioDuckFactor"]
        ),
        .executable(
            name: "duck-audio-replay-probe",
            targets: ["DuckAudioReplayProbe"]
        ),
        .executable(
            name: "duck-audio-selftest",
            targets: ["DuckAudioSelfTest"]
        ),
        .executable(
            name: "duck-audio-engine",
            targets: ["DuckAudioEngine"]
        ),
        .executable(
            name: "DuckAudioApp",
            targets: ["DuckAudioApp"]
        )
    ],
    targets: [
        .target(
            name: "DuckAudioCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "DuckAudioPhase0",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioTapMeter",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioDuckFactor",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioReplayProbe",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioSelfTest",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioEngine",
            dependencies: ["DuckAudioCore"]
        ),
        .executableTarget(
            name: "DuckAudioApp",
            dependencies: ["DuckAudioCore"]
        )
    ]
)
