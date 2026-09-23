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
        // ponytail: absolute path until v1 feat/ringkit merges, then "../v1/apps/ios"
        .package(name: "Guv", path: "/Users/adi/code/v1/.worktrees/feat/ringkit/apps/ios")
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
            dependencies: ["MimiSpeech", "MimiAEC", .product(name: "RingKit", package: "Guv")],
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
            dependencies: ["Mimi", "MimiSpeech", "MimiAEC", .product(name: "RingKit", package: "Guv")],
            path: "Tests/MimiTests",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
