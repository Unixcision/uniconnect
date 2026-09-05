// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXAgentVault",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXAgentVault",
            targets: ["CMUXAgentVault"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite3",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "CMUXAgentVault",
            dependencies: [.target(name: "CSQLite3", condition: .when(platforms: [.linux]))],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CMUXAgentVaultTests",
            dependencies: ["CMUXAgentVault", .target(name: "CSQLite3", condition: .when(platforms: [.linux]))],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
