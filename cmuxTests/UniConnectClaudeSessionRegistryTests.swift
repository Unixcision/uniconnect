import Foundation
import Testing
import UniConnectClaudeBridge

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect Claude session signal registry")
struct UniConnectClaudeSessionRegistryTests {
    private actor LocalSource: UniConnectClaudeSessionSignalStreaming {
        let stream: AsyncStream<UniConnectClaudeSessionSignal>

        init(stream: AsyncStream<UniConnectClaudeSessionSignal>) {
            self.stream = stream
        }

        func signals() -> AsyncStream<UniConnectClaudeSessionSignal> {
            stream
        }
    }

    @Test("Routes local transitions only to the exact workspace and panel")
    func exactLocalRouting() async throws {
        let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let panelID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let surfaceGeneration = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let local = AsyncStream<UniConnectClaudeSessionSignal>.makeStream()
        let registry = UniConnectClaudeSessionRegistry()
        await registry.start(localSignals: LocalSource(stream: local.stream), remoteSignals: nil)
        let events = await registry.events(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: surfaceGeneration
        )
        let next = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        local.continuation.yield(UniConnectClaudeSessionSignal(
            workspaceID: workspaceID,
            panelID: UUID(),
            kind: .shellActivityChanged,
            lifecycle: nil,
            shellActivity: "prompt_idle"
        ))
        local.continuation.yield(UniConnectClaudeSessionSignal(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: UUID(),
            kind: .shellActivityChanged,
            lifecycle: nil,
            shellActivity: "prompt_idle"
        ))
        let expected = UniConnectClaudeSessionSignal(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: surfaceGeneration,
            kind: .shellActivityChanged,
            lifecycle: nil,
            shellActivity: "command_running"
        )
        local.continuation.yield(expected)

        let event = try #require(await next.value)
        #expect(event == .local(expected))
        await registry.stop()
        local.continuation.finish()
    }

    @Test("Rejects stale lifecycle transitions for a generation-bound subscriber")
    func lifecycleRequiresExactSurfaceGeneration() async throws {
        let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let panelID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let surfaceGeneration = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let local = AsyncStream<UniConnectClaudeSessionSignal>.makeStream()
        let registry = UniConnectClaudeSessionRegistry()
        await registry.start(localSignals: LocalSource(stream: local.stream), remoteSignals: nil)
        let events = await registry.events(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: surfaceGeneration
        )
        let next = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        local.continuation.yield(UniConnectClaudeSessionSignal(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: UUID(),
            kind: .lifecycleChanged,
            lifecycle: "idle",
            shellActivity: nil
        ))
        let expected = UniConnectClaudeSessionSignal(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: surfaceGeneration,
            kind: .lifecycleChanged,
            lifecycle: "running",
            shellActivity: nil
        )
        local.continuation.yield(expected)

        let event = try #require(await next.value)
        #expect(event == .local(expected))
        await registry.stop()
        local.continuation.finish()
    }

    @Test("Keeps the newest authenticated remote signal for one route")
    func newestRemoteSignalWins() async throws {
        let routeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let local = AsyncStream<UniConnectClaudeSessionSignal>.makeStream()
        let remote = AsyncStream<ClaudeBridgeSessionSignal>.makeStream()
        let registry = UniConnectClaudeSessionRegistry()
        await registry.start(
            localSignals: LocalSource(stream: local.stream),
            remoteSignals: remote.stream
        )
        let newest = ClaudeBridgeSessionSignal(
            routeID: routeID,
            sessionID: "44444444-4444-4444-8444-444444444444",
            cwd: "/srv/project",
            tmuxPane: "%4",
            kind: .sessionStart,
            occurredAt: Date(timeIntervalSince1970: 200)
        )
        let older = ClaudeBridgeSessionSignal(
            routeID: routeID,
            sessionID: "55555555-5555-4555-8555-555555555555",
            cwd: "/srv/old",
            tmuxPane: "%5",
            kind: .stop,
            occurredAt: Date(timeIntervalSince1970: 100)
        )
        remote.continuation.yield(newest)
        remote.continuation.yield(older)
        remote.continuation.finish()

        try await Task.sleep(for: .milliseconds(20))
        let observed = await registry.latestRemoteSignal(routeID: routeID)
        #expect(observed == newest)
        await registry.stop()
        local.continuation.finish()
    }

    @Test("Ignores a delayed close signal after the same panel ID respawns")
    @MainActor
    func stalePanelCloseDoesNotCancelReplacementOwner() {
        let closedGeneration = UUID()
        let replacementGeneration = UUID()
        #expect(
            !UniConnectCoordinator.shouldCancelLocalAgentLaunchForPanelClosedSignal(
                signalGeneration: closedGeneration,
                currentGeneration: replacementGeneration,
                hasCurrentPanel: true
            )
        )
        #expect(
            UniConnectCoordinator.shouldCancelLocalAgentLaunchForPanelClosedSignal(
                signalGeneration: closedGeneration,
                currentGeneration: nil,
                hasCurrentPanel: false
            )
        )
        #expect(
            !UniConnectCoordinator.shouldCancelLocalAgentLaunchForPanelClosedSignal(
                signalGeneration: nil,
                currentGeneration: nil,
                hasCurrentPanel: false
            )
        )
    }
}
