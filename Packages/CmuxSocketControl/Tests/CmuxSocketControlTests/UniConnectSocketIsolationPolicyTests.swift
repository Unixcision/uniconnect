import Testing

@testable import CmuxSocketControl

@Suite struct UniConnectSocketIsolationPolicyTests {
    private let releaseBundleIdentifier = "com.unixcision.uniconnect"
    private let debugBundleIdentifier = "com.unixcision.uniconnect.debug.isolation"

    @Test func acceptsUniConnectAndNeutralEndpointsFromUniConnectCLI() {
        for endpoint in [
            "/tmp/uniconnect-debug-test.sock",
            "/Users/test/.local/state/uniconnect/uniconnect.sock",
            "/tmp/cli-test-fixture.sock",
            "127.0.0.1:64123",
            "localhost:64123",
        ] {
            #expect(
                UniConnectSocketIsolationPolicy.permitsConnection(
                    to: endpoint,
                    executableBundleIdentifier: debugBundleIdentifier,
                    environment: ["CMUX_BUNDLE_ID": debugBundleIdentifier]
                ),
                "Expected UniConnect to accept \(endpoint)"
            )
        }
    }

    @Test(arguments: [
        "/tmp/cmux.sock",
        "/private/tmp/CMUX-debug-other-app.sock",
        "/Users/test/.local/state/cmux/control.sock",
        "/Users/test/.cmux/control.sock",
        "/Users/test/.config/cmux/control.sock",
        "/Users/test/Library/Application Support/cmux/control.sock",
        "/Users/test/Library/Application Support/com.cmuxterm.app/control.sock",
    ])
    func rejectsForeignCmuxNamespace(endpoint: String) {
        #expect(
            !UniConnectSocketIsolationPolicy.permitsConnection(
                to: endpoint,
                executableBundleIdentifier: releaseBundleIdentifier,
                environment: [:]
            )
        )
    }

    @Test func rejectsSocketInheritedFromForeignAppContext() {
        #expect(
            !UniConnectSocketIsolationPolicy.permitsConnection(
                to: "/tmp/uniconnect-looking-but-inherited.sock",
                executableBundleIdentifier: releaseBundleIdentifier,
                environment: ["CMUX_BUNDLE_ID": "com.cmuxterm.app"]
            )
        )
    }

    @Test func rejectsCLIExecutableOutsideUniConnectBundle() {
        #expect(
            !UniConnectSocketIsolationPolicy.permitsConnection(
                to: "/tmp/uniconnect.sock",
                executableBundleIdentifier: "com.example.other-app",
                environment: [:]
            )
        )
    }

    @Test func exactOneInvocationOptInAllowsForeignEndpoint() {
        #expect(
            UniConnectSocketIsolationPolicy.permitsConnection(
                to: "/tmp/cmux-debug-explicit.sock",
                executableBundleIdentifier: releaseBundleIdentifier,
                environment: [
                    "CMUX_BUNDLE_ID": "com.cmuxterm.app",
                    UniConnectSocketIsolationPolicy.allowForeignSocketEnvironmentKey: "1",
                ]
            )
        )
        #expect(
            !UniConnectSocketIsolationPolicy.permitsConnection(
                to: "/tmp/cmux-debug-explicit.sock",
                executableBundleIdentifier: releaseBundleIdentifier,
                environment: [
                    UniConnectSocketIsolationPolicy.allowForeignSocketEnvironmentKey: "true",
                ]
            )
        )
    }

    @Test func rejectsBlankEndpoint() {
        #expect(
            !UniConnectSocketIsolationPolicy.permitsConnection(
                to: "  ",
                executableBundleIdentifier: releaseBundleIdentifier,
                environment: [:]
            )
        )
    }
}
