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
    targets: [
        .target(
            name: "MimiSpeech",
            path: "Sources/MimiSpeech"
        ),
        .executableTarget(
            name: "Mimi",
            dependencies: ["MimiSpeech"],
            path: "Sources/Mimi"
        ),
        .executableTarget(
            name: "MimiSmoke",
            dependencies: ["MimiSpeech"],
            path: "Sources/MimiSmoke"
        ),
        .testTarget(
            name: "MimiTests",
            dependencies: ["Mimi"],
            path: "Tests/MimiTests"
        )
    ]
)
