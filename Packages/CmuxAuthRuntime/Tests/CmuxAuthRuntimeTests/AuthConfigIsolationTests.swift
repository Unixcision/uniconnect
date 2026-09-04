import CMUXAuthCore
@testable import CmuxAuthRuntime
import Testing

@Suite struct AuthConfigIsolationTests {
    @Test func unconfiguredBuildNeverFallsBackToUpstreamTenant() {
        for environment in [CMUXAuthEnvironment.development, .production] {
            let config = AuthConfig(environment: environment)
            #expect(config.stack.projectId == "00000000-0000-4000-8000-000000000000")
            #expect(config.stack.publishableClientKey == "unconfigured-uniconnect-publishable-key")
        }
    }

    @Test func deploymentCanInjectItsOwnTenant() {
        let config = AuthConfig(
            environment: .production,
            overrides: [
                "STACK_PROJECT_ID_PROD": "uniconnect-project",
                "STACK_PUBLISHABLE_CLIENT_KEY_PROD": "uniconnect-key",
            ]
        )

        #expect(config.stack.projectId == "uniconnect-project")
        #expect(config.stack.publishableClientKey == "uniconnect-key")
    }
}
