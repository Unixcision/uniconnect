import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite struct AuthEnvironmentHostedServicesPolicyTests {
    private let completeEnvironment: [String: String] = [
        "UNICONNECT_HOSTED_SERVICES_ENABLED": "1",
        "CMUX_STACK_PROJECT_ID": "CB533F96-02C1-49E2-A26B-FBB103FA17DD",
        "CMUX_STACK_PUBLISHABLE_CLIENT_KEY": "uniconnect-test-publishable-key",
        "CMUX_AUTH_WWW_ORIGIN": "https://account.uniconnect.test",
        "CMUX_API_BASE_URL": "https://api.uniconnect.test",
        "CMUX_VM_API_BASE_URL": "https://cloud.uniconnect.test",
    ]

    @Test func defaultsToUnavailableWithoutExplicitEnablement() {
        var environment = completeEnvironment
        environment.removeValue(forKey: "UNICONNECT_HOSTED_SERVICES_ENABLED")

        #expect(resolve(environment) == nil)
    }

    @Test func partialConfigurationFailsClosed() {
        var environment = completeEnvironment
        environment.removeValue(forKey: "CMUX_VM_API_BASE_URL")

        #expect(resolve(environment) == nil)
    }

    @Test func completeExplicitHTTPSConfigurationResolves() throws {
        let configuration = try #require(resolve(completeEnvironment))

        #expect(configuration.stackProjectID == completeEnvironment["CMUX_STACK_PROJECT_ID"])
        #expect(configuration.authWebsiteOrigin.absoluteString == "https://account.uniconnect.test")
        #expect(configuration.apiBaseURL.absoluteString == "https://api.uniconnect.test")
        #expect(configuration.vmAPIBaseURL.absoluteString == "https://cloud.uniconnect.test")
    }

    @Test func remotePlaintextEndpointIsRejectedEvenForDebugPolicy() {
        var environment = completeEnvironment
        environment["CMUX_API_BASE_URL"] = "http://api.uniconnect.test"

        #expect(resolve(environment, allowsInsecureLoopback: true) == nil)
    }

    @Test func loopbackHTTPRequiresExplicitDebugAllowance() {
        var environment = completeEnvironment
        environment["CMUX_AUTH_WWW_ORIGIN"] = "http://localhost:3777"
        environment["CMUX_API_BASE_URL"] = "http://127.0.0.1:3777"
        environment["CMUX_VM_API_BASE_URL"] = "http://localhost:3777"

        #expect(resolve(environment, allowsInsecureLoopback: false) == nil)
        #expect(resolve(environment, allowsInsecureLoopback: true) != nil)
    }

    @Test func inheritedProductAndPlaceholderValuesAreRejected() {
        var inheritedHost = completeEnvironment
        inheritedHost["CMUX_AUTH_WWW_ORIGIN"] = "https://github.com/Unixcision/uniconnect"
        #expect(resolve(inheritedHost) == nil)

        var placeholderProject = completeEnvironment
        placeholderProject["CMUX_STACK_PROJECT_ID"] = "00000000-0000-4000-8000-000000000000"
        #expect(resolve(placeholderProject) == nil)
    }

    @Test @MainActor func nilConfigurationDoesNotConstructMacAuthGraph() {
        let composition = MacAuthComposition(
            configuration: nil,
            environment: [:],
            defaults: UserDefaults(suiteName: "AuthEnvironmentHostedServicesPolicyTests")!
        )

        #expect(composition == nil)
    }

    private func resolve(
        _ environment: [String: String],
        allowsInsecureLoopback: Bool = false
    ) -> AuthEnvironment.HostedServicesConfiguration? {
        AuthEnvironment.hostedServicesConfiguration(
            environment: environment,
            infoDictionary: [:],
            allowsInsecureLoopback: allowsInsecureLoopback
        )
    }
}

// The resolver only exists in DEBUG (it is the macOS dogfood auto-sign-in seam,
// compiled out of release builds), so the whole suite is DEBUG-gated. In a
// release test build there is nothing to test: the auto-sign-in path does not
// exist, which is the production guarantee.
#if DEBUG
@Suite struct DebugDogfoodCredentialResolverTests {
    /// Build a resolver over an ordered list of `(path, contents)` secret-file
    /// fakes, so a test never reads the real `~/.secrets` files and the file
    /// precedence order is deterministic (a plain `[String: String]` would
    /// iterate in undefined key order).
    private func makeResolver(
        environment: [String: String],
        files: [(path: String, contents: String)] = []
    ) -> DebugDogfoodCredentialResolver {
        let table = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        return DebugDogfoodCredentialResolver(
            environment: environment,
            secretFilePaths: files.map(\.path),
            readFile: { table[$0] }
        )
    }

    @Test func noCredentialsAnywhereResolvesNil() {
        let resolver = makeResolver(environment: ["HOME": "/Users/test"])
        #expect(resolver.resolve() == nil)
    }

    @Test func dogfoodEnvCredentialsResolve() {
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "owner@uniconnect.example",
            "CMUX_DOGFOOD_STACK_PASSWORD": "dog-pw",
        ])
        #expect(
            resolver.resolve()
                == .init(email: "owner@uniconnect.example", password: "dog-pw")
        )
    }

    @Test func uitestEnvCredentialsResolveWhenNoDogfood() {
        let resolver = makeResolver(environment: [
            "CMUX_UITEST_STACK_EMAIL": "agent-dev@uniconnect.example",
            "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
        ])
        #expect(
            resolver.resolve()
                == .init(email: "agent-dev@uniconnect.example", password: "agent-pw")
        )
    }

    @Test func dogfoodAccountWinsOverUitestAccountAcrossSources() {
        // The dog Mac case: the agent (uitest) creds are in the environment, but
        // the human dogfood creds are only in a secret file. Dogfood must win so
        // the dog Mac comes up as lawrence, not the agent account.
        let resolver = makeResolver(
            environment: [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@uniconnect.example",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            files: [
                (
                    "/secrets/uniconnect-dev.env",
                    """
                    CMUX_DOGFOOD_STACK_EMAIL=owner@uniconnect.example
                    CMUX_DOGFOOD_STACK_PASSWORD=dog-pw
                    """
                ),
            ]
        )
        #expect(
            resolver.resolve()
                == .init(email: "owner@uniconnect.example", password: "dog-pw")
        )
    }

    @Test func envWinsOverFileWithinSameAccount() {
        let resolver = makeResolver(
            environment: [
                "CMUX_DOGFOOD_STACK_EMAIL": "env@uniconnect.example",
                "CMUX_DOGFOOD_STACK_PASSWORD": "env-pw",
            ],
            files: [
                (
                    "/secrets/uniconnect-dev.env",
                    """
                    CMUX_DOGFOOD_STACK_EMAIL=file@uniconnect.example
                    CMUX_DOGFOOD_STACK_PASSWORD=file-pw
                    """
                ),
            ]
        )
        #expect(
            resolver.resolve()
                == .init(email: "env@uniconnect.example", password: "env-pw")
        )
    }

    @Test func earlierFileWinsOverLaterFile() {
        // uniconnect-dev.env is listed before uniconnect.env, so it takes precedence.
        let resolver = DebugDogfoodCredentialResolver(
            environment: [:],
            secretFilePaths: ["/secrets/uniconnect-dev.env", "/secrets/uniconnect.env"],
            readFile: { path in
                switch path {
                case "/secrets/uniconnect-dev.env":
                    return """
                    CMUX_DOGFOOD_STACK_EMAIL=devfile@uniconnect.example
                    CMUX_DOGFOOD_STACK_PASSWORD=dev-pw
                    """
                case "/secrets/uniconnect.env":
                    return """
                    CMUX_DOGFOOD_STACK_EMAIL=general@uniconnect.example
                    CMUX_DOGFOOD_STACK_PASSWORD=cmux-pw
                    """
                default:
                    return nil
                }
            }
        )
        #expect(
            resolver.resolve()
                == .init(email: "devfile@uniconnect.example", password: "dev-pw")
        )
    }

    @Test func fallsThroughToUniConnectEnvFileWhenDevFileLacksCreds() {
        let resolver = DebugDogfoodCredentialResolver(
            environment: [:],
            secretFilePaths: ["/secrets/uniconnect-dev.env", "/secrets/uniconnect.env"],
            readFile: { path in
                switch path {
                case "/secrets/uniconnect-dev.env":
                    return "# no stack creds here\nE2B_API_KEY=abc\n"
                case "/secrets/uniconnect.env":
                    return """
                    CMUX_UITEST_STACK_EMAIL=agent@uniconnect.example
                    CMUX_UITEST_STACK_PASSWORD=agent-pw
                    """
                default:
                    return nil
                }
            }
        )
        #expect(
            resolver.resolve()
                == .init(email: "agent@uniconnect.example", password: "agent-pw")
        )
    }

    @Test func partialCredentialPairIsIgnored() {
        // Email without password must not yield a half-resolved credential.
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "owner@uniconnect.example",
        ])
        #expect(resolver.resolve() == nil)
    }

    @Test func emptyCredentialValuesAreIgnored() {
        let resolver = makeResolver(environment: [
            "CMUX_DOGFOOD_STACK_EMAIL": "",
            "CMUX_DOGFOOD_STACK_PASSWORD": "",
        ])
        #expect(resolver.resolve() == nil)
    }

    @Test func parsesQuotedAndCommentedEnvFile() {
        let parsed = DebugDogfoodCredentialResolver.parseEnvFile(
            """
            # comment line
            CMUX_DOGFOOD_STACK_EMAIL="owner@uniconnect.example"
            CMUX_DOGFOOD_STACK_PASSWORD='secret value'

            BLANK_AFTER=1
            """
        )
        #expect(parsed["CMUX_DOGFOOD_STACK_EMAIL"] == "owner@uniconnect.example")
        #expect(parsed["CMUX_DOGFOOD_STACK_PASSWORD"] == "secret value")
        #expect(parsed["BLANK_AFTER"] == "1")
    }
}

/// Integration coverage for the `MacAuthComposition` wrapper that feeds resolved
/// creds into `AuthLaunchOptions`. The wrapper, not the resolver, is where a
/// regression would re-introduce the "agent creds in env shadow the dogfood
/// file" bug, so these tests drive the wrapper directly with injected file
/// fakes.
@Suite struct MacAuthCompositionDogfoodAutoSignInTests {
    @Test func dogfoodFileWinsOverAgentEnvCredsOnDogMac() {
        // Dog-Mac scenario: agent (uitest) creds in the environment, human
        // dogfood creds only in the secret file. The build must come up as the
        // human dogfood account, so the file creds win and overwrite the env
        // uitest keys that AuthLaunchOptions reads.
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@uniconnect.example",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            secretFilePaths: ["/secrets/uniconnect-dev.env"],
            readFile: { _ in
                """
                CMUX_DOGFOOD_STACK_EMAIL=owner@uniconnect.example
                CMUX_DOGFOOD_STACK_PASSWORD=dog-pw
                """
            }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == "owner@uniconnect.example")
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == "dog-pw")
    }

    @Test func leavesAgentEnvCredsWhenNoDogfoodFile() {
        // CI UI-test scenario: only uitest env creds, no secret file. The
        // resolver returns that same pair, so the merge is a no-op.
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            [
                "CMUX_UITEST_STACK_EMAIL": "agent-dev@uniconnect.example",
                "CMUX_UITEST_STACK_PASSWORD": "agent-pw",
            ],
            secretFilePaths: ["/secrets/uniconnect-dev.env"],
            readFile: { _ in nil }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == "agent-dev@uniconnect.example")
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == "agent-pw")
    }

    @Test func injectsNothingWhenNoCredentialsAvailable() {
        let merged = MacAuthComposition.environmentWithDogfoodAutoSignIn(
            ["HOME": "/Users/test"],
            secretFilePaths: ["/secrets/uniconnect-dev.env"],
            readFile: { _ in nil }
        )
        #expect(merged["CMUX_UITEST_STACK_EMAIL"] == nil)
        #expect(merged["CMUX_UITEST_STACK_PASSWORD"] == nil)
    }
}
#endif
