// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniConnectTranscriptRetention",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "UniConnectTranscriptRetention",
            targets: ["UniConnectTranscriptRetention"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxProcess"),
    ],
    targets: [
        .target(
            name: "UniConnectTranscriptRetention",
            dependencies: [
                .product(name: "CmuxProcess", package: "CmuxProcess"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "UniConnectTranscriptRetentionTests",
            dependencies: ["UniConnectTranscriptRetention"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
