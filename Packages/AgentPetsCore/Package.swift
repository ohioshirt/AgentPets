// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPetsCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AgentPetsCore", targets: ["AgentPetsCore"]),
        .executable(name: "agentpets-hook", targets: ["agentpets-hook"]),
    ],
    targets: [
        .target(name: "AgentPetsCore"),
        .executableTarget(name: "agentpets-hook", dependencies: ["AgentPetsCore"]),
        .testTarget(
            name: "AgentPetsCoreTests",
            dependencies: ["AgentPetsCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
