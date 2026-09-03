import Testing
@testable import CmuxSocketControl

@Test func markerFilesAreVariantAware() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.unixcision.uniconnect",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.unixcision.uniconnect.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.unixcision.uniconnect.debug.agent",
        environment: [:]
    ) == .dev(slug: "agent"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.unixcision.uniconnect.debug",
        environment: ["CMUX_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.unixcision.uniconnect.debug",
        environment: ["CMUX_TAG": "café"]
    ) == .dev(slug: "caf"))
}

@Test func defaultSocketPathsStayVariantScoped() {
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.unixcision.uniconnect",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/uniconnect.sock"
    ) == "/stable/uniconnect.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.unixcision.uniconnect.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/uniconnect.sock"
    ) == "/tmp/uniconnect-nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.unixcision.uniconnect.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/uniconnect.sock"
    ) == "/tmp/uniconnect-staging-my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.unixcision.uniconnect.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/uniconnect.sock"
    ) == "/tmp/uniconnect-debug-issue-3542.sock")
}
