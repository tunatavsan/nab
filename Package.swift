// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nab",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NabApp", targets: ["NabApp"]),
        .executable(name: "nab", targets: ["NabCLI"]),
        .library(name: "NabCore", targets: ["NabCore"]),
        .library(name: "NabYouTube", targets: ["NabYouTube"]),
        .library(name: "NabAI", targets: ["NabAI"]),
    ],
    targets: [
        .target(name: "NabCore"),
        .target(name: "NabYouTube", dependencies: ["NabCore"]),
        .executableTarget(name: "NabCLI", dependencies: ["NabCore", "NabYouTube"]),
        .target(name: "NabAI", dependencies: ["NabCore"]),
        .executableTarget(name: "NabApp", dependencies: ["NabCore", "NabYouTube", "NabAI"]),
        .testTarget(name: "NabTests", dependencies: ["NabCore", "NabYouTube", "NabAI"]),
    ]
)
