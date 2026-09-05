// swift-tools-version: 6.0
import Foundation
import PackageDescription

// CI copies selected production files into a disposable harness. This tests the
// actual app-domain implementation without launching Ghostty or a user's app.
let repository = ProcessInfo.processInfo.environment["UNICONNECT_TEST_REPO"]!
let package = Package(
    name: "UniConnectMobileBehavior",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: repository + "/Packages/CMUXMobileCore"),
        .package(path: repository + "/Packages/CmuxProcess"),
    ],
    targets: [
        .target(name: "cmux", dependencies: ["CMUXMobileCore", "CmuxProcess"]),
        .testTarget(name: "UniConnectMobileBehaviorTests", dependencies: ["cmux", "CMUXMobileCore", "CmuxProcess"]),
    ]
)
