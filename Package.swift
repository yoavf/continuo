// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "agent-sync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentSyncCore", targets: ["AgentSyncCore"]),
        .executable(name: "AgentSyncCLI", targets: ["AgentSyncCLI"]),
        .executable(name: "AgentSyncApp", targets: ["AgentSyncApp"])
    ],
    targets: [
        .target(
            name: "AgentSyncCore",
            resources: [.copy("Resources/model-contexts.json")]
        ),
        .executableTarget(
            name: "AgentSyncCLI",
            dependencies: ["AgentSyncCore"]
        ),
        .executableTarget(
            name: "AgentSyncApp",
            dependencies: ["AgentSyncCore"],
            resources: [
                .copy("Resources/splash-1.png"),
                .copy("Resources/splash-2.png")
            ]
        ),
        .testTarget(
            name: "AgentSyncCoreTests",
            dependencies: ["AgentSyncCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
