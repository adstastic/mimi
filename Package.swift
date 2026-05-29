// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sokki",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Sokki", targets: ["Sokki"]),
        .executable(name: "SokkiSmoke", targets: ["SokkiSmoke"])
    ],
    targets: [
        .target(
            name: "SokkiSpeech",
            path: "Sources/SokkiSpeech"
        ),
        .executableTarget(
            name: "Sokki",
            dependencies: ["SokkiSpeech"],
            path: "Sources/Sokki"
        ),
        .executableTarget(
            name: "SokkiSmoke",
            dependencies: ["SokkiSpeech"],
            path: "Sources/SokkiSmoke"
        ),
        .testTarget(
            name: "SokkiTests",
            dependencies: ["Sokki"],
            path: "Tests/SokkiTests"
        )
    ]
)
