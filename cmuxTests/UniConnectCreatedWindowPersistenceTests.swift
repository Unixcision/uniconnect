import Testing
import AppKit
import Bonsplit
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A window created from the phone or the desktop is saved at once, and again with its agent's
/// conversation as soon as a targeted probe finds it, without waiting for the autosave timer.
///
/// `.serialized` because the integration cases drive the shared `TerminalController` and
/// `UniConnectCoordinator` with real `TabManager`/`Workspace` models.
@MainActor
@Suite(.serialized)
struct UniConnectCreatedWindowPersistenceTests {
    /// Answers every wait at once: the schedule is exercised without real time passing.
    private static let immediate: @Sendable (Duration) async throws -> Void = { _ in try Task.checkCancellation() }

    @Test("Saves at once, probes until the conversation appears, then saves again")
    func savesNowAndAgainWhenCaptured() async {
        var saves = 0
        var probes = 0
        let persistence = UniConnectCreatedWindowPersistence(
            save: { saves += 1 },
            capture: { _ in
                probes += 1
                return probes < 3 ? .pending : .captured
            },
            sleep: Self.immediate
        )
        await persistence.windowCreated(.init(workspaceID: UUID(), panelID: UUID()), expectsAgent: true).value
        #expect(probes == 3)
        #expect(saves == 2)
    }

    @Test("A plain terminal is saved once and never probed")
    func plainTerminalIsSavedOnce() async {
        var saves = 0
        var probes = 0
        let persistence = UniConnectCreatedWindowPersistence(
            save: { saves += 1 },
            capture: { _ in probes += 1; return .captured },
            sleep: Self.immediate
        )
        await persistence.windowCreated(.init(workspaceID: UUID(), panelID: UUID()), expectsAgent: false).value
        #expect(saves == 1)
        #expect(probes == 0)
    }

    @Test("The wait is bounded: an agent that never files a conversation stops the probes")
    func waitIsBounded() async {
        var saves = 0
        var probes = 0
        let persistence = UniConnectCreatedWindowPersistence(
            save: { saves += 1 },
            capture: { _ in probes += 1; return .pending },
            sleep: Self.immediate,
            probeDelays: [.seconds(1), .seconds(2), .seconds(3)]
        )
        await persistence.windowCreated(.init(workspaceID: UUID(), panelID: UUID()), expectsAgent: true).value
        #expect(probes == 3)
        #expect(saves == 1)
    }

    @Test("Closing the window cancels the wait")
    func closingCancelsTheWait() async {
        var probes = 0
        let (gate, opener) = AsyncStream<Void>.makeStream()
        let owner = UniConnectCreatedWindowPersistence.Owner(workspaceID: UUID(), panelID: UUID())
        let persistence = UniConnectCreatedWindowPersistence(
            save: { opener.yield() },
            capture: { _ in probes += 1; return .pending },
            sleep: { _ in
                // Holds until cancelled, like a real delay that is interrupted.
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }
        )
        let task = persistence.windowCreated(owner, expectsAgent: true)
        var saved = gate.makeAsyncIterator()
        _ = await saved.next()
        persistence.windowClosed(owner)
        await task.value
        #expect(probes == 0)
    }

    @Test("Claude is saved with the conversation id it was started on, before any probe")
    func claudeIsSavedWithItsChosenConversation() async throws {
        let manager = TabManager()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectChosenSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try #require(manager.selectedWorkspace)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: root.path)
        let coordinator = UniConnectCoordinator.shared
        let previous = coordinator.createdWindowPersistence
        let (saves, sink) = AsyncStream<UniConnectDocument.Workspace>.makeStream()
        coordinator.configureCreatedWindowPersistence(UniConnectCreatedWindowPersistence(
            save: {
                sink.yield(UniConnectBackup.documentWorkspace(
                    workspace, groupNames: [:], agentIndex: .empty, reconcileLiveState: false
                ))
            },
            capture: { _ in .unavailable },
            sleep: Self.immediate
        ))
        defer { coordinator.configureCreatedWindowPersistence(previous) }
        let request = try #require(UniConnectNewLocalWindowRequest(
            visibleName: "Claude Code", boxRoot: root.path, launchTarget: .claude
        ))
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(coordinator.createLocalWindow(
            in: workspace, request: request, focus: false, showErrors: false,
            placement: .tab(paneID: pane, afterTabID: nil)
        ))
        defer { panel.surface.teardownSurface() }
        let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panel.id])
        let chosen = try #require(record.launch?.sessionID)
        #expect(UUID(uuidString: chosen) != nil)
        // The probe sees it in argv even when the agent runs as a user it cannot read.
        let binding = try #require(record.tmuxBinding)
        let agentCommand = try #require(UniConnectLocalWindowLaunchTarget.claude.startupCommand(
            boxRoot: record.boxRoot, workingDirectory: record.workingDirectory,
            extraArguments: ["--session-id", chosen]
        ))
        #expect(agentCommand.contains("'--session-id' '\(chosen)'"))
        #expect(panel.surface.initialCommand == UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: record.workingDirectory, initialCommand: agentCommand
        ).startupCommand())
        var saved = saves.makeAsyncIterator()
        let first = try #require(await saved.next())
        let window = try #require(first.windows.first { $0.localWindow?.id == panel.id })
        #expect(window.localWindow?.activeConversation?.sessionID == chosen)
        #expect(window.claudeSession == chosen)
    }

    // Through `createLocalWindow`, the creation path the desktop sheets and `mobile.terminal.create`
    // share. The phone's RPC also starts the terminal in the background, which here would launch a
    // real agent, so the shared path is driven directly.
    @Test("A created window is saved with its folder, tmux session and agent, then with its conversation")
    func mobileCreationIsSavedAtOnceThenWithItsConversation() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectInstantSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try #require(manager.selectedWorkspace)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: root.path)

        let conversation = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"
        let inspector = ConversationInspector(sessionID: conversation)
        let (documents, sink) = AsyncStream<UniConnectDocument.Workspace>.makeStream()
        let coordinator = UniConnectCoordinator.shared
        let previous = coordinator.createdWindowPersistence
        coordinator.configureCreatedWindowPersistence(UniConnectCreatedWindowPersistence(
            // What «Guardar» would write for this workspace at that moment.
            save: {
                sink.yield(UniConnectBackup.documentWorkspace(
                    workspace, groupNames: [:], agentIndex: .empty,
                    reconcileLiveState: false
                ))
            },
            capture: { owner in
                let found = await coordinator.captureLocalAgent(panelID: owner.panelID, in: workspace, inspector: inspector)
                // A probe that finds nothing ends the stream instead of leaving the test waiting.
                if found != .captured { sink.finish() }
                return found
            },
            sleep: Self.immediate
        ))
        defer { coordinator.configureCreatedWindowPersistence(previous) }

        let request = try #require(UniConnectNewLocalWindowRequest(
            visibleName: "Codex", boxRoot: root.path, launchTarget: .codex
        ))
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(coordinator.createLocalWindow(
            in: workspace, request: request, focus: false, showErrors: false,
            placement: .tab(paneID: pane, afterTabID: nil)
        ))
        let panelID = panel.id
        defer { panel.surface.teardownSurface() }

        var saved = documents.makeAsyncIterator()
        let first = try #require(await saved.next())
        let window = try #require(first.windows.first { $0.localWindow?.id == panelID })
        let record = try #require(window.localWindow)
        let expectedRoot = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(root.path))
        #expect(first.kind == .local)
        #expect(window.name == "Codex")
        #expect(record.launch?.agent == "codex")
        #expect(record.workingDirectory == expectedRoot)
        #expect(record.tmuxBinding == workspace.uniConnectLocalWindowsByPanelId[panelID]?.tmuxBinding)
        #expect(record.tmuxBinding != nil)
        #expect(record.activeConversation == nil)

        let second = try #require(await saved.next())
        let captured = try #require(second.windows.first { $0.localWindow?.id == panelID }?.localWindow)
        #expect(captured.activeConversation?.kind == .codex)
        #expect(captured.activeConversation?.sessionID == conversation)
    }
}

/// A probe that finds one Codex conversation in whatever pane it is asked about.
private struct ConversationInspector: UniConnectLocalTmuxInspecting {
    let sessionID: String

    func runtimeObservations(
        for targets: [UniConnectLocalTmuxRuntimeObservation.Target]
    ) async -> [UniConnectLocalTmuxRuntimeObservation] {
        targets.map { target in
            UniConnectLocalTmuxRuntimeObservation(
                target: target,
                state: .discovered(AgentObservedConversation(
                    provider: .codex, sessionID: sessionID,
                    workingDirectory: target.record.workingDirectory,
                    asRoot: false, source: .sessionFile, processID: 4242
                ))
            )
        }
    }

    func generation(for binding: UniConnectLocalTmuxBinding, workspaceID: UUID, panelID: UUID) async -> UUID? { nil }

    func verifiedOwner(
        of peer: UniConnectLocalTmuxProcessIdentity,
        among owners: [UniConnectLocalTmuxOwner]
    ) async -> UniConnectLocalTmuxOwner? { nil }

    func liveIdentity(binding: UniConnectLocalTmuxBinding) async -> UniConnectLocalTmuxLiveIdentity? { nil }
}
