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
        ),
        .executable(
            name: "agent-injection-menu",
            targets: ["AgentInjectionMenu"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/johnno1962/InjectionLite",
            revision: "63db51348e9d91f0faeaab54206e390175b6f327"
        ),
        .package(
            url: "https://github.com/johnno1962/SwiftRegex5",
            .upToNextMajor(from: "6.3.0")
        )
    ],
    targets: [
        .target(
            name: "AgentInjectionCore",
            dependencies: [
                .product(
                    name: "InjectionImpl",
                    package: "InjectionLite"
                ),
                .product(
                    name: "InjectionLite",
                    package: "InjectionLite"
                ),
                .product(
                    name: "SwiftRegexD",
                    package: "SwiftRegex5"
                )
            ]
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
        .executableTarget(
            name: "AgentInjectionMenu",
            dependencies: ["AgentInjectionCore"]
        ),
        .testTarget(
            name: "AgentInjectionCoreTests",
            dependencies: ["AgentInjectionCore"]
        )
    ]
)
