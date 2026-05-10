// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TravelRunner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.17.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "TravelRunner",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/TravelRunner",
            resources: [.process("Resources")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "TravelRunnerTests",
            dependencies: ["TravelRunner"],
            path: "Tests/TravelRunnerTests"
        ),
    ]
)
