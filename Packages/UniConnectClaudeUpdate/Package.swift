// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniConnectClaudeUpdate",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "UniConnectClaudeUpdate",
            targets: ["UniConnectClaudeUpdate"]
        ),
    ],
    targets: [
        .target(
            name: "UniConnectClaudeUpdate",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "UniConnectClaudeUpdateTests",
            dependencies: ["UniConnectClaudeUpdate"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
