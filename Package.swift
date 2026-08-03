// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mimi",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Mimi", targets: ["Mimi"]),
        .executable(name: "MimiSmoke", targets: ["MimiSmoke"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", exact: "14.5.0")
    ],
    targets: [
        .target(
            name: "MimiSpeech",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MimiSpeech"
        ),
        .binaryTarget(
            name: "MimiAEC",
            path: "Vendor/MimiAEC.xcframework"
        ),
        .executableTarget(
            name: "Mimi",
            dependencies: [
                "MimiSpeech",
                "MimiAEC",
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "DSWaveformImageViews", package: "DSWaveformImage")
            ],
            path: "Sources/Mimi",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "MimiSmoke",
            dependencies: ["MimiSpeech"],
            path: "Sources/MimiSmoke"
        ),
        .testTarget(
            name: "MimiTests",
            dependencies: ["Mimi", "MimiSpeech", "MimiAEC"],
            path: "Tests/MimiTests",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
