import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeConnectionAttemptRegressionTests {
    @Test("Reconnect attempts never reuse the previous remote listener address")
    func freshConnectionAttemptsNeverReuseRemoteListenerAddress() throws {
        let route = BridgeTestMessages.route()
        let installationID = String(repeating: "a", count: 32)
        let forwards = try (0..<2).map { _ in
            let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
                route: route,
                installationID: installationID,
                localListenerPort: 49_321
            )
            let forwardIndex = try #require(plan.sshOptions.firstIndex(of: "-R"))
            return try #require(plan.sshOptions.dropFirst(forwardIndex + 1).first)
        }

        #expect(forwards[0] != forwards[1])
    }
}
