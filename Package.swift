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
        .library(name: "NabSources", targets: ["NabSources"]),
    ],
    targets: [
        .target(name: "NabCore"),
        .target(name: "NabYouTube", dependencies: ["NabCore"]),
        // Every source Nab reads, listed once; the app and the CLI both take the list from here.
        .target(name: "NabSources", dependencies: ["NabCore", "NabYouTube"]),
        .executableTarget(name: "NabCLI", dependencies: ["NabCore", "NabSources"]),
        .target(name: "NabAI", dependencies: ["NabCore"]),
        .executableTarget(name: "NabApp", dependencies: ["NabCore", "NabYouTube", "NabAI", "NabSources"]),
        .testTarget(name: "NabTests", dependencies: ["NabCore", "NabYouTube", "NabAI", "NabSources"]),
    ]
)
