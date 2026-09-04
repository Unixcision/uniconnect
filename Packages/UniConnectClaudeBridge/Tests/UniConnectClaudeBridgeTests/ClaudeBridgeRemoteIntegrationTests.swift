import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeRemoteIntegrationTests {
    @Test
    func rendersSameConnectionPortAndLoopbackForwardForAStableRoute() {
        let routeID = UUID(uuidString: "12345678-1234-4234-9234-1234567890ab")!
        let route = BridgeTestMessages.route(id: routeID)
        let first = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_321
        )
        let second = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_321
        )

        #expect(first == second)
        #expect(first.sshOptions.contains("ExitOnForwardFailure=yes"))
        #expect(first.sshOptions.contains {
            $0.hasPrefix("127.0.0.1:") && $0.hasSuffix(":127.0.0.1:49321")
        })
        #expect((42_000...61_999).contains(Int(ClaudeBridgeRemoteIntegration.remoteForwardPort(for: routeID))))
    }

    @Test
    func remoteIntegrationUsesOfficialLifecycleHooksAndOwnsReversibleEntries() {
        let route = BridgeTestMessages.route()
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "b", count: 32),
            localListenerPort: 50_001
        )

        #expect(plan.remoteSetupCommand.contains("\"Stop\""))
        #expect(plan.remoteSetupCommand.contains("\"Notification\""))
        #expect(plan.remoteSetupCommand.contains("idle_prompt"))
        #expect(plan.remoteSetupCommand.contains("\"UserPromptSubmit\""))
        #expect(plan.remoteSetupCommand.contains("\"SessionStart\""))
        #expect(plan.remoteSetupCommand.contains("remove_owned_hooks"))
        #expect(plan.remoteSetupCommand.contains("settings-"))
        #expect(plan.remoteSetupCommand.contains("JsonLayoutParser"))
        #expect(plan.remoteSetupCommand.contains("safe_restore"))
        #expect(!plan.remoteSetupCommand.contains("json.dumps(document, ensure_ascii=False, indent=2)"))
        #expect(plan.remoteCleanupCommand.contains("unregister"))
        #expect(plan.remoteCleanupCommand.contains(route.id.uuidString.lowercased()))
    }

    @Test
    func remoteSessionContractIsAtomicPrivateAndContentMinimal() {
        let route = BridgeTestMessages.route()
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "c", count: 32),
            localListenerPort: 50_002
        )

        #expect(plan.remoteSetupCommand.contains(".session.json"))
        #expect(plan.remoteSetupCommand.contains("persist_session_record"))
        #expect(plan.remoteSetupCommand.contains("atomic_write"))
        #expect(plan.remoteSetupCommand.contains("0o600"))
        #expect(plan.remoteSetupCommand.contains("\"session_id\""))
        #expect(plan.remoteSetupCommand.contains("\"cwd\""))
        #expect(plan.remoteSetupCommand.contains("\"tmux_pane\""))
        #expect(plan.remoteSetupCommand.contains("\"activity_state\""))
        #expect(plan.remoteSetupCommand.contains("\"observed_at_ms\""))
        #expect(plan.remoteSetupCommand.contains("\"prompt_correlation\""))
        #expect(plan.remoteSetupCommand.contains("fcntl.LOCK_EX"))
        #expect(!plan.remoteSetupCommand.contains("source.get(\"prompt\")"))
        #expect(!plan.remoteSetupCommand.contains("transcript_path"))
    }

    @Test
    func remoteJournalRejectsLateCompletionFromAnOlderPrompt() {
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: BridgeTestMessages.route(),
            installationID: String(repeating: "d", count: 32),
            localListenerPort: 50_003
        )

        #expect(plan.remoteSetupCommand.contains("current_prompt != prompt_correlation"))
        #expect(plan.remoteSetupCommand.contains("current_timestamp > timestamp_ms"))
        #expect(plan.remoteSetupCommand.contains("normalized_prompt_correlation(source.get(\"prompt_id\"))"))
    }

    @Test
    func multiRouteCleanupTransfersOneCurrentScriptAndNamesEveryRoute() {
        let first = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let command = ClaudeBridgeRemoteIntegration.remoteCleanupCommand(
            routeIDs: [second, first, first],
            installationID: String(repeating: "e", count: 32)
        )

        #expect(command.contains(first.uuidString.lowercased()))
        #expect(command.contains(second.uuidString.lowercased()))
        #expect(command.components(separatedBy: "printf '%s'").count == 2)
    }
}
