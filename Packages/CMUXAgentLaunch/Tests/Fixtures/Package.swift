// swift-tools-version: 6.0
import PackageDescription

// An isolated test fixture, never an exported CMUXAgentLaunch product.
let package = Package(
    name: "AgentResumeProbeFixture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "AgentResumeProbe",
            dependencies: [.product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch")],
            path: "AgentResumeProbe"
        ),
    ]
)
