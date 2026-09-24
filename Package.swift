// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "agentInjectionIII",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AgentInjectionCore",
            targets: ["AgentInjectionCore"]
        ),
        .library(
            name: "AgentInjectionIntegration",
            targets: ["AgentInjectionIntegration"]
        ),
        .executable(
            name: "injectiond",
            targets: ["injectiond"]
        ),
        .executable(
            name: "injectionctl",
            targets: ["injectionctl"]
        )
    ],
    targets: [
        .target(
            name: "AgentInjectionCore"
        ),
        .target(
            name: "AgentInjectionIntegration",
            path: "Integration",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "injectiond",
            dependencies: ["AgentInjectionCore"]
        ),
        .executableTarget(
            name: "injectionctl",
            dependencies: ["AgentInjectionCore"]
        ),
        .testTarget(
            name: "AgentInjectionCoreTests",
            dependencies: ["AgentInjectionCore"]
        )
    ]
)
