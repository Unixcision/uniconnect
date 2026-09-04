// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniConnectClaudeBridge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "UniConnectClaudeBridge",
            targets: ["UniConnectClaudeBridge"]
        ),
    ],
    targets: [
        .target(
            name: "UniConnectClaudeBridge",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "UniConnectClaudeBridgeTests",
            dependencies: ["UniConnectClaudeBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
