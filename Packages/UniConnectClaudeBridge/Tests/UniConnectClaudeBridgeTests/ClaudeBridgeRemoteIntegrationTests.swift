import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeRemoteIntegrationTests {
    @Test
    func rendersSamePrivateUnixSocketForwardForOneConnectionAttempt() {
        let routeID = UUID(uuidString: "12345678-1234-4234-9234-1234567890ab")!
        let route = BridgeTestMessages.route(id: routeID)
        let installationID = String(repeating: "a", count: 32)
        let connectionID = UUID()
        let first = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: 49_321,
            connectionID: connectionID
        )
        let second = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: 49_321,
            connectionID: connectionID
        )
        let socketPath = ClaudeBridgeRemoteIntegration.remoteForwardSocketPath(
            for: routeID,
            installationID: installationID,
            connectionID: connectionID
        )

        #expect(first == second)
        #expect(first.sshOptions.contains("ExitOnForwardFailure=no"))
        #expect(first.sshOptions.contains("ClearAllForwardings=no"))
        #expect(first.sshOptions.contains("StreamLocalBindMask=0177"))
        #expect(first.sshOptions.contains("StreamLocalBindUnlink=yes"))

        #expect(first.sshOptions.contains("\(socketPath):127.0.0.1:49321"))
        #expect(socketPath.utf8.count == 79)
        #expect(
            socketPath.range(
                of: #"^/tmp/ucb-[0-9a-f]{32}-[0-9a-f]{32}\.sock$"#,
                options: .regularExpression
            ) != nil
        )
        #expect(!first.sshOptions.contains(where: { $0.contains("0.0.0.0") || $0.contains("*") }))
        #expect(!first.sshOptions.contains(where: { $0.hasPrefix("127.0.0.1:") }))
    }

    @Test
    func newRoutesUseUnixSocketsWhileTheScriptCanReadLiveLegacyTCPRoutes() {
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: BridgeTestMessages.route(),
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_322
        )

        #expect(plan.remoteSetupCommand.contains("\"socket_path\": endpoint"))
        #expect(plan.remoteSetupCommand.contains("elif socket_path is None and route.get(\"connection_id\") is None:"))
        #expect(plan.remoteSetupCommand.contains("legacy_port = int(route.get(\"port\", 0))"))
        #expect(plan.remoteSetupCommand.contains("endpoint = legacy_port"))
        #expect(!plan.remoteSetupCommand.contains("\"port\": args.port"))
        #expect(!plan.remoteSetupCommand.contains("registration.add_argument(\"--port\""))
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
        #expect(plan.remoteSetupCommand.contains("LIFECYCLE_LOCK"))
        #expect(
            plan.remoteSetupCommand.components(separatedBy: "with lifecycle_lock():").count == 4
        )
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
    func remoteJournalRejectsOlderWritesWithoutHashingPromptText() {
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: BridgeTestMessages.route(),
            installationID: String(repeating: "d", count: 32),
            localListenerPort: 50_003
        )

        #expect(plan.remoteSetupCommand.contains("current_prompt != prompt_correlation"))
        #expect(plan.remoteSetupCommand.contains("current_timestamp > timestamp_ms"))
        #expect(plan.remoteSetupCommand.contains("normalized_prompt_correlation(source.get(\"prompt_id\"))"))
        #expect(!plan.remoteSetupCommand.contains("normalized_prompt_correlation(source.get(\"prompt\"))"))
    }

    @Test
    func promptHookStopsAfterUpdatingPrivateJournal() {
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: BridgeTestMessages.route(),
            installationID: String(repeating: "f", count: 32),
            localListenerPort: 50_004
        )

        #expect(plan.remoteSetupCommand.contains("if kind == \"prompt\":\n            return 0"))
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

    @Test("Reconnect keeps the route identity but allocates a fresh transport path")
    func reconnectDoesNotReusePreviousForwardSocket() {
        let route = BridgeTestMessages.route()
        let first = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 51234
        )
        let second = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 51234
        )
        #expect(first.routeID == second.routeID)
        #expect(first.sshOptions != second.sshOptions)
        #expect(first.remoteCleanupCommand == second.remoteCleanupCommand)
    }

}
