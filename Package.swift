// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sokki",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Sokki", targets: ["Sokki"])
    ],
    targets: [
        .executableTarget(
            name: "Sokki",
            path: "Sources/Sokki"
        ),
        .testTarget(
            name: "SokkiTests",
            dependencies: ["Sokki"],
            path: "Tests/SokkiTests"
        )
    ]
)
