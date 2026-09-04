import Foundation
import Testing
import UniConnectClaudeBridge
import UniConnectClaudeUpdate

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect Claude remote target resolver")
struct UniConnectClaudeRemoteTargetResolverTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Rejects an unauthenticated remote session record")
    func rejectsMissingSignal() async {
        let fixture = makeFixture(signal: nil, activity: "idle")
        #expect(await fixture.resolver.resolve(workspace: fixture.workspace, panel: fixture.panel) == nil)
    }

    @Test("Rejects a stale authenticated completion")
    func rejectsStaleSignal() async {
        let fixture = makeFixture(
            signalKind: .stop,
            signalDate: now.addingTimeInterval(-601),
            activity: "idle"
        )
        #expect(await fixture.resolver.resolve(workspace: fixture.workspace, panel: fixture.panel) == nil)
    }

    @Test("Rejects an old idle signal after a newer prompt made the record running")
    func rejectsIdleSignalForRunningRecord() async {
        let fixture = makeFixture(signalKind: .stop, activity: "running")
        #expect(await fixture.resolver.resolve(workspace: fixture.workspace, panel: fixture.panel) == nil)
    }

    @Test("Accepts a fresh authenticated stop for the exact UUID, cwd, and pane")
    func acceptsFreshExactIdleSignal() async {
        let fixture = makeFixture(signalKind: .stop, activity: "idle")
        let resolution = await fixture.resolver.resolve(
            workspace: fixture.workspace,
            panel: fixture.panel
        )
        #expect(resolution?.binding.sessionID == fixture.sessionID)
        #expect(resolution?.pane.paneID == "%7")
    }

    @Test("Accepts authenticated prompt state without misclassifying it as idle")
    func acceptsAuthenticatedRunningSignal() async {
        let fixture = makeFixture(signalKind: .userPromptSubmit, activity: "running")
        let resolution = await fixture.resolver.resolve(
            workspace: fixture.workspace,
            panel: fixture.panel
        )
        #expect(resolution?.binding.sessionID == fixture.sessionID)
    }

    private func makeFixture(
        signal: ClaudeBridgeSessionSignal? = nil,
        signalKind: ClaudeBridgeEventKind? = nil,
        signalDate: Date? = nil,
        activity: String
    ) -> ResolverFixture {
        let workspaceID = UUID()
        let panelID = UUID()
        let credentialID = UUID()
        let sessionID = UUID()
        let occurredAt = signalDate ?? now
        let resolvedSignal = signalKind.map { kind in
            ClaudeBridgeSessionSignal(
                routeID: panelID,
                sessionID: sessionID.uuidString.lowercased(),
                cwd: "/srv/app",
                tmuxPane: "%7",
                kind: kind,
                occurredAt: occurredAt
            )
        } ?? signal
        let timestamp = Int64((occurredAt.timeIntervalSince1970 * 1_000).rounded())
        let payload: [String: Any] = [
            "version": 1,
            "session_id": sessionID.uuidString.lowercased(),
            "working_directory": "/srv/app",
            "runtime_cwd": "/srv/app",
            "executable_path": "/usr/bin/claude",
            "session_name": "work",
            "window_index": 0,
            "pane_index": 0,
            "pane_id": "%7",
            "process_id": 42,
            "is_idle": activity == "idle",
            "record_session_kind": "uuid",
            "record_activity_state": activity,
            "record_observed_at_ms": timestamp,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let runner = ResolverProcessRunner(output: data)
        let resolver = UniConnectClaudeRemoteTargetResolver(
            processRunner: runner,
            binaryUpdater: ResolverBinaryUpdater(),
            credentialResolver: { requestedID in
                requestedID == credentialID ? "ssh test@example.invalid" : nil
            },
            installationID: String(repeating: "a", count: 32),
            signalProvider: { requestedRoute in
                requestedRoute == panelID ? resolvedSignal : nil
            },
            currentDate: { now }
        )
        let workspace = UniConnectClaudeUpdateWorkspaceSnapshot(
            id: workspaceID,
            boxID: workspaceID.uuidString.lowercased(),
            displayName: "Fixture",
            kind: .ssh,
            credentialID: credentialID,
            hostLabel: "test@example.invalid",
            panels: []
        )
        let panel = UniConnectClaudeUpdatePanelSnapshot(
            id: panelID,
            workspaceID: workspaceID,
            displayName: "Claude",
            directory: "/srv/app",
            persistedClaudeSessionID: nil,
            tmuxSession: "work",
            isDisconnected: false,
            lifecycle: nil,
            shellActivity: nil,
            restorableAgent: nil
        )
        return ResolverFixture(
            resolver: resolver,
            workspace: workspace,
            panel: panel,
            sessionID: sessionID
        )
    }
}

private struct ResolverFixture {
    let resolver: UniConnectClaudeRemoteTargetResolver
    let workspace: UniConnectClaudeUpdateWorkspaceSnapshot
    let panel: UniConnectClaudeUpdatePanelSnapshot
    let sessionID: UUID
}

private actor ResolverProcessRunner: UniConnectProcessRunning {
    let output: Data

    init(output: Data) {
        self.output = output
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: Duration
    ) async throws -> UniConnectProcessResult {
        UniConnectProcessResult(
            terminationStatus: 0,
            standardOutput: output,
            standardError: Data(),
            outputWasTruncated: false
        )
    }
}

private struct ResolverBinaryUpdater: ClaudeBinaryUpdating {
    func installedVersion(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeVersion {
        ClaudeVersion(major: 1, minor: 0, patch: 0)
    }

    func update(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeUpdateCommandResult {
        ClaudeUpdateCommandResult(
            exitCode: 0,
            didTimeOut: false,
            standardOutput: "",
            standardError: ""
        )
    }
}
