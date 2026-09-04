import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect local-window actions")
struct UniConnectLocalWindowActionPolicyTests {
    private let emptyRegistry = CmuxVaultAgentRegistry(registrations: [])

    @Test("Built-in agents launch with the requested trust policy and keep the login shell")
    func builtInLaunchCommandsUseBoxRootAndReturnToShell() throws {
        let root = "/Users/test/Box Root"

        let claude = try #require(UniConnectLocalWindowLaunchTarget.claude.startupCommand(boxRoot: root))
        #expect(claude.contains("cd -- '/Users/test/Box Root'"))
        #expect(claude.contains("'claude' '--dangerously-skip-permissions'"))
        #expect(!claude.contains("exec "))

        let codex = try #require(UniConnectLocalWindowLaunchTarget.codex.startupCommand(boxRoot: root))
        #expect(codex.contains("'codex' '--yolo'"))
        #expect(!codex.contains("exec "))

        let agy = try #require(UniConnectLocalWindowLaunchTarget.agy.startupCommand(boxRoot: root))
        #expect(agy.contains("'agy' '--dangerously-skip-permissions'"))
        #expect(!agy.contains("exec "))

        let grok = try #require(UniConnectLocalWindowLaunchTarget.grok.startupCommand(boxRoot: root))
        #expect(grok.hasSuffix("&& 'grok'"))
        #expect(!grok.contains("exec "))

        let apiClaude = try #require(
            UniConnectLocalWindowLaunchTarget.claude.startupCommand(
                boxRoot: root,
                workingDirectory: "/Users/test/Box Root/api"
            )
        )
        #expect(apiClaude.contains("cd -- '/Users/test/Box Root/api'"))
    }

    @Test("A new terminal request has no command and never accepts a missing root")
    func terminalRequestUsesAuthoritativeRoot() throws {
        let request = try #require(
            UniConnectNewLocalWindowRequest(
                visibleName: "",
                boxRoot: "/Users/test/repository",
                launchTarget: .terminal
            )
        )
        #expect(request.visibleName == "Terminal")
        #expect(request.boxRoot == "/Users/test/repository")
        #expect(request.startupInput == nil)
        #expect(
            UniConnectNewLocalWindowRequest(
                visibleName: "Terminal",
                boxRoot: "   ",
                launchTarget: .terminal
            ) == nil
        )
    }

    @Test("Local commands require a live directory and never fall through to the shell cwd")
    func localRootGuardPreventsHomeFallback() throws {
        let missing = "/tmp/uniconnect-missing-\(UUID().uuidString)"
        #expect(!UniConnectLocalBoxRootPolicy.isAvailableDirectory(missing))
        #expect(UniConnectLocalBoxRootPolicy.isAvailableDirectory(NSTemporaryDirectory()))

        let command = try #require(
            UniConnectLocalBoxRootPolicy.commandRequiringAvailableRoot(
                "'claude' '--dangerously-skip-permissions'",
                root: "/Users/test/Box Root"
            )
        )
        #expect(command == "cd -- '/Users/test/Box Root' && 'claude' '--dangerously-skip-permissions'")
        #expect(!command.contains("|| [ ! -d"))
        #expect(
            UniConnectLocalBoxRootPolicy.safeShellFallbackDirectory(
                currentDirectory: missing,
                missingRoot: missing
            ) != missing
        )
    }

    @Test("A deleted per-window cwd reopens in its trusted root without losing the saved path")
    func deletedWindowDirectoryUsesTrustedRootFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-window-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("deleted", isDirectory: true).path
        let record = localRecord(root: root.path, workingDirectory: missing)

        let plan = try #require(
            UniConnectLocalWindowAction.reopenTerminal
                .terminalLaunchPlan(record: record, registry: emptyRegistry)
        )

        #expect(plan.workingDirectory == root.path)
        #expect(record.workingDirectory == missing)
        #expect(plan.operation == .openShell)
    }

    @Test("A deleted per-window cwd resumes and starts agents in the live trusted root")
    func deletedWindowDirectoryAgentActionsUseTrustedRootFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-agent-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("deleted", isDirectory: true).path
        var record = localRecord(root: root.path, workingDirectory: missing)
        _ = record.record(snapshot(.codex, sessionID: "codex-fallback-thread"), at: 11)
        _ = record.transitionToShell(at: 12)
        let conversationID = try #require(record.latestConversationID)

        let resumePlan = try #require(
            UniConnectLocalWindowAction.resumeConversation(conversationID)
                .terminalLaunchPlan(record: record, registry: emptyRegistry)
        )
        guard case .runCommand(let resumeCommand) = resumePlan.operation else {
            Issue.record("Expected a resume command")
            return
        }
        #expect(resumePlan.workingDirectory == root.path)
        #expect(resumeCommand.contains("cd -- '\(root.path)'"))
        #expect(!resumeCommand.contains(missing))
        #expect(resumeCommand.contains("'codex' 'resume' 'codex-fallback-thread' '--yolo'"))

        let startPlan = try #require(
            UniConnectLocalWindowAction.startAgent(.agy)
                .terminalLaunchPlan(record: record, registry: emptyRegistry)
        )
        guard case .runCommand(let startCommand) = startPlan.operation else {
            Issue.record("Expected an agent start command")
            return
        }
        #expect(startPlan.workingDirectory == root.path)
        #expect(startCommand == "cd -- '\(root.path)' && 'agy' '--dangerously-skip-permissions'")
        #expect(record.workingDirectory == missing)
    }

    @Test("A missing saved root exposes reassignment and disables every agent launch")
    func missingRootMenuPreservesRecoveryWithoutLaunching() throws {
        var record = localRecord(root: "/tmp/uniconnect-deleted-root")
        _ = record.record(snapshot(.claude, sessionID: "missing-root-session"), at: 15)
        _ = record.transitionToShell(at: 16)

        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(
            record: record,
            boxRootIsAvailable: false
        )

        #expect(menu.preferredRecoveryAction?.action == .reassignBoxRoot)
        #expect(!menu.runtimeTitle.isEmpty)
        #expect(menu.agentActions.allSatisfy { !$0.isEnabled })
        #expect(menu.recoveryActions.filter { $0.action != .reassignBoxRoot }.allSatisfy { !$0.isEnabled })
        #expect(record.conversations.count == 1)
        #expect(
            !UniConnectLocalBoxRootPolicy.allowsAutomaticResume(
                settingEnabled: true,
                agentWasRunningAtQuit: true,
                boxRootIsAvailable: false
            )
        )
    }

    @Test("Reassigning the local root updates the durable window without losing history")
    @MainActor
    func reassignedRootPreservesConversationHistory() throws {
        let originalRoot = NSTemporaryDirectory()
        let reassignedRoot = FileManager.default.homeDirectoryForCurrentUser.path
        let workspace = Workspace(workingDirectory: originalRoot)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: originalRoot
        )
        workspace.uniConnectConfigureLocalRoot(originalRoot)
        let panelID = try #require(workspace.focusedPanelId)
        _ = workspace.uniConnectRecordLocalAgent(
            panelId: panelID,
            snapshot: snapshot(.codex, sessionID: "reassigned-root-session"),
            at: 90
        )
        _ = workspace.uniConnectTransitionLocalWindowToShell(panelId: panelID, at: 91)

        workspace.uniConnectConfigureLocalRoot(reassignedRoot)

        #expect(workspace.uniConnectProfile?.localRoot == reassignedRoot)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.boxRoot == reassignedRoot)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.conversations.count == 1)
        #expect(
            workspace.uniConnectLocalWindowsByPanelId[panelID]?.latestConversation?.sessionID
                == "reassigned-root-session"
        )
    }

    @Test("Live directory reports update only the per-window cwd, never the trusted root")
    @MainActor
    func liveDirectoryReportTracksBoundedWindowWorkingDirectory() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-live-cwd-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("repo", isDirectory: true)
        let api = root.appendingPathComponent("api", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let workspace = Workspace(workingDirectory: root.path)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: root.path
        )
        workspace.uniConnectConfigureLocalRoot(root.path)
        let panelID = try #require(workspace.focusedPanelId)

        #expect(workspace.updatePanelDirectory(panelId: panelID, directory: api.path))
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.boxRoot == root.path)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.workingDirectory == api.path)

        #expect(workspace.updatePanelDirectory(panelId: panelID, directory: outside.path))
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.boxRoot == root.path)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.workingDirectory == api.path)
    }

    @Test("Declining auto-resume leaves the latest conversation visible and resumable")
    func shellStateKeepsVisibleResumeAction() throws {
        var record = localRecord()
        _ = record.record(snapshot(.claude, sessionID: "claude-session-1"), at: 11)
        _ = record.transitionToShell(at: 12)

        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(record: record)
        let preferred = try #require(menu.preferredRecoveryAction)

        #expect(preferred.action == .resumeConversation(try #require(record.latestConversationID)))
        #expect(preferred.isEnabled)
        #expect(menu.forgetActions.count == 1)
    }

    @Test("A stopped shell offers both reopening and saved-session recovery")
    func stoppedWindowOffersRecoveryWithoutForgetting() throws {
        var record = localRecord()
        _ = record.record(snapshot(.codex, sessionID: "codex-thread-1"), at: 21)
        _ = record.markStopped(at: 22)

        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(record: record)

        #expect(menu.recoveryActions.first?.action == .reopenTerminal)
        #expect(menu.recoveryActions.contains { descriptor in
            if case .resumeConversation = descriptor.action { return true }
            return false
        })
        #expect(record.conversations.count == 1)
    }

    @Test("Previous conversations remain selectable after switching agents")
    func previousConversationHistoryIsSelectable() throws {
        var record = localRecord()
        _ = record.record(snapshot(.claude, sessionID: "claude-session-2"), at: 31)
        let claudeID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 32)
        _ = record.record(snapshot(.antigravity, sessionID: "agy-conversation-1"), at: 33)
        _ = record.transitionToShell(at: 34)

        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(record: record)

        #expect(menu.historyActions.map(\.action) == [.resumeConversation(claudeID)])
        #expect(menu.forgetActions.count == 2)
        #expect(record.conversations.map(\.kind) == [.claude, .antigravity])
    }

    @Test("Resume commands ignore captured cwd and use the saved per-window cwd")
    func resumePlanUsesSavedWorkingDirectory() throws {
        var record = localRecord(
            root: "/Users/test/Trusted Root",
            workingDirectory: "/Users/test/Trusted Root/api"
        )
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "codex-thread-2",
                workingDirectory: "/tmp/wrong-cwd",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: nil,
                    executablePath: "codex",
                    arguments: ["codex", "--yolo"],
                    workingDirectory: "/tmp/wrong-cwd",
                    environment: nil,
                    capturedAt: 40,
                    source: "test"
                )
            ),
            at: 41
        )
        _ = record.transitionToShell(at: 42)
        let conversationID = try #require(record.latestConversationID)

        let plan = try #require(
            UniConnectLocalWindowAction.resumeConversation(conversationID)
                .terminalLaunchPlan(record: record, registry: emptyRegistry)
        )

        #expect(plan.boxRoot == "/Users/test/Trusted Root")
        #expect(plan.workingDirectory == "/Users/test/Trusted Root/api")
        guard case .runCommand(let command) = plan.operation else {
            Issue.record("Expected a resume command")
            return
        }
        #expect(command.contains("cd -- '/Users/test/Trusted Root/api'"))
        #expect(!command.contains("/tmp/wrong-cwd"))
        #expect(command.contains("'codex' 'resume' 'codex-thread-2' '--yolo'"))
        #expect(plan.startupInput?.hasSuffix("\n") == true)
    }

    @Test("An active agent blocks accidental nested launches until slash-exit")
    func activeAgentDisablesSwitching() {
        var record = localRecord()
        _ = record.record(snapshot(.claude, sessionID: "claude-session-3"), at: 51)

        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(record: record)

        #expect(menu.recoveryActions.isEmpty)
        #expect(menu.agentActions.allSatisfy { !$0.isEnabled })
        #expect(menu.forgetActions.allSatisfy { !$0.isEnabled })
        #expect(
            UniConnectLocalWindowAction.startAgent(.agy)
                .terminalLaunchPlan(record: record, registry: emptyRegistry) == nil
        )
    }

    @Test("Forgetting is modeled as an explicit destructive action, never a terminal command")
    func forgetIsExplicitAndNonLaunching() throws {
        var record = localRecord()
        _ = record.record(snapshot(.grok, sessionID: "grok-session-1"), at: 61)
        _ = record.transitionToShell(at: 62)
        let conversationID = try #require(record.latestConversationID)
        let menu = UniConnectLocalWindowActionPolicy.menuSnapshot(record: record)
        let forget = try #require(menu.forgetActions.first)

        #expect(forget.action == .forgetConversation(conversationID))
        #expect(forget.role == .destructive)
        #expect(
            forget.action.terminalLaunchPlan(record: record, registry: emptyRegistry) == nil
        )
        #expect(record.conversations.count == 1)
    }

    @Test("Manual resume is armed before input and command-running marks the saved agent active")
    @MainActor
    func manualResumeTransitionsThroughAwaitingAndBackToShell() throws {
        let root = "/tmp/uniconnect-manual-resume"
        let workspace = Workspace(workingDirectory: root)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: root
        )
        workspace.uniConnectConfigureLocalRoot(root)
        let panelID = try #require(workspace.focusedPanelId)
        let saved = snapshot(.claude, sessionID: "claude-manual-resume")
        #expect(workspace.uniConnectRecordLocalAgent(panelId: panelID, snapshot: saved, at: 70))
        #expect(workspace.uniConnectTransitionLocalWindowToShell(panelId: panelID, at: 71))

        #expect(workspace.uniConnectPrepareLocalAgentLaunch(panelId: panelID, snapshot: saved))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == .awaitingAutoResumeCommand)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.runtimeState == .shell)

        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == .autoResumeCommandRunning)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.runtimeState == .agent)

        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == .manualResumeAvailable)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.runtimeState == .shell)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.conversations.count == 1)
    }

    @Test("A launch timeout returns to manual recovery without deleting history")
    @MainActor
    func cancellingPreparedResumePreservesSavedLink() throws {
        let root = "/tmp/uniconnect-cancel-resume"
        let workspace = Workspace(workingDirectory: root)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: root
        )
        workspace.uniConnectConfigureLocalRoot(root)
        let panelID = try #require(workspace.focusedPanelId)
        let saved = snapshot(.codex, sessionID: "codex-cancel-resume")
        _ = workspace.uniConnectRecordLocalAgent(panelId: panelID, snapshot: saved, at: 80)
        _ = workspace.uniConnectTransitionLocalWindowToShell(panelId: panelID, at: 81)
        #expect(workspace.uniConnectPrepareLocalAgentLaunch(panelId: panelID, snapshot: saved))

        #expect(workspace.uniConnectCancelPreparedLocalAgentLaunch(panelId: panelID))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == .manualResumeAvailable)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.runtimeState == .shell)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.latestConversation?.sessionID == "codex-cancel-resume")
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID]?.conversations.count == 1)
    }

    @Test("Forced SSH reconnect bypasses stale disconnected state and resets its budget")
    func forcedReconnectPolicyHandlesHungConnections() {
        #expect(
            UniConnectSSHReconnectPolicy.nextAttempt(
                trigger: .userForced,
                isDisconnected: false,
                attemptsSpent: 3,
                maximumAutomaticAttempts: 3,
                hasReconnectInFlight: false
            ) == 1
        )
    }

    @Test("Forced SSH teardown targets only the terminal foreground process group")
    func forcedReconnectTerminationPlanIsScopedToPTYJob() throws {
        let plan = try #require(
            UniConnectSSHProcessTerminationPlan.make(
                foregroundPID: 4_321,
                processGroupID: 4_300,
                applicationProcessGroupID: 900
            )
        )
        #expect(plan.foregroundPID == 4_321)
        #expect(plan.processGroupID == 4_300)
        #expect(plan.signalTarget == -4_300)

        let sameAsApp = try #require(
            UniConnectSSHProcessTerminationPlan.make(
                foregroundPID: 4_321,
                processGroupID: 900,
                applicationProcessGroupID: 900
            )
        )
        #expect(sameAsApp.processGroupID == nil)
        #expect(sameAsApp.signalTarget == 4_321)
        #expect(
            UniConnectSSHProcessTerminationPlan.make(
                foregroundPID: 1,
                processGroupID: 1,
                applicationProcessGroupID: 900
            ) == nil
        )
    }

    @Test("Automatic SSH reconnect remains disconnected-only, bounded, and single-flight")
    func automaticReconnectPolicyStaysBounded() {
        #expect(
            UniConnectSSHReconnectPolicy.nextAttempt(
                trigger: .automatic,
                isDisconnected: false,
                attemptsSpent: 0,
                maximumAutomaticAttempts: 3,
                hasReconnectInFlight: false
            ) == nil
        )
        #expect(
            UniConnectSSHReconnectPolicy.nextAttempt(
                trigger: .automatic,
                isDisconnected: true,
                attemptsSpent: 2,
                maximumAutomaticAttempts: 3,
                hasReconnectInFlight: false
            ) == 3
        )
        #expect(
            UniConnectSSHReconnectPolicy.nextAttempt(
                trigger: .automatic,
                isDisconnected: true,
                attemptsSpent: 3,
                maximumAutomaticAttempts: 3,
                hasReconnectInFlight: false
            ) == nil
        )
        #expect(
            UniConnectSSHReconnectPolicy.nextAttempt(
                trigger: .userForced,
                isDisconnected: true,
                attemptsSpent: 0,
                maximumAutomaticAttempts: 3,
                hasReconnectInFlight: true
            ) == nil
        )
    }

    @Test("SSH reconnect stays single-flight across boxes until the exact lease finishes")
    @MainActor
    func reconnectFlightRegistryUsesGlobalTargetAndGeneration() throws {
        let target = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@example.test",
                port: 22,
                tmuxSession: "main"
            )
        )
        let registry = UniConnectSSHReconnectFlightRegistry()
        let first = try #require(registry.begin(target))

        #expect(registry.contains(target))
        #expect(registry.begin(target) == nil)
        #expect(registry.finish(first))

        let successor = try #require(registry.begin(target))
        #expect(successor.generation != first.generation)
        #expect(!registry.finish(first))
        #expect(registry.contains(target))
        #expect(registry.finish(successor))
        #expect(!registry.contains(target))
    }

    @Test("A reconnect claim stays owned through stability and stale completion cannot end its successor")
    @MainActor
    func reconnectLeaseCoversTheWholeStabilityWindow() throws {
        let target = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@example.test",
                port: 22,
                tmuxSession: "main"
            )
        )
        let registry = UniConnectSSHReconnectFlightRegistry()
        let stabilityLease = try #require(registry.begin(target))

        #expect(registry.begin(target) == nil)
        #expect(registry.contains(target))
        #expect(registry.finish(stabilityLease))

        let successor = try #require(registry.begin(target))
        #expect(!registry.finish(stabilityLease))
        #expect(registry.contains(target))
        #expect(registry.finish(successor))
    }

    @Test("Bulk SSH reconnect deduplicates one logical tmux target deterministically")
    func bulkReconnectDeduplicatesLogicalTargets() {
        let workspaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let firstPanelID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let duplicatePanelID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let otherPanelID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let candidates = [
            UniConnectSSHReconnectPolicy.Candidate(
                workspaceID: workspaceID,
                panelID: duplicatePanelID,
                tmuxSession: "main"
            ),
            UniConnectSSHReconnectPolicy.Candidate(
                workspaceID: workspaceID,
                panelID: otherPanelID,
                tmuxSession: "logs"
            ),
            UniConnectSSHReconnectPolicy.Candidate(
                workspaceID: workspaceID,
                panelID: firstPanelID,
                tmuxSession: "main"
            ),
        ]

        let result = UniConnectSSHReconnectPolicy.deduplicatedCandidates(candidates)

        #expect(result.count == 2)
        #expect(result.contains { $0.panelID == otherPanelID })
        #expect(result.contains { $0.panelID == firstPanelID })
        #expect(!result.contains { $0.panelID == duplicatePanelID })
    }

    @Test("Bulk SSH reconnect deduplicates the same endpoint and tmux across boxes and credentials")
    func bulkReconnectDeduplicatesEndpointTargetsGlobally() throws {
        let firstWorkspaceID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
        let secondWorkspaceID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
        let firstPanelID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        let secondPanelID = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
        let firstKey = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@Example.COM.",
                port: nil,
                tmuxSession: "main"
            )
        )
        let secondKey = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@example.com",
                port: 22,
                tmuxSession: "main"
            )
        )

        let result = UniConnectSSHReconnectPolicy.deduplicatedCandidates([
            .init(
                workspaceID: secondWorkspaceID,
                panelID: secondPanelID,
                tmuxSession: "main",
                targetKey: secondKey
            ),
            .init(
                workspaceID: firstWorkspaceID,
                panelID: firstPanelID,
                tmuxSession: "main",
                targetKey: firstKey
            ),
        ])

        #expect(result.map(\.panelID) == [firstPanelID])
    }

    @Test("Legacy duplicate SSH records elect one reconnect owner instead of blocking each other")
    func duplicateSSHTargetElectsCanonicalReconnectOwner() throws {
        let target = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@example.test",
                port: 22,
                tmuxSession: "main"
            )
        )
        let first = UniConnectSSHReconnectPolicy.Candidate(
            workspaceID: UUID(uuidString: "21100000-0000-0000-0000-000000000001")!,
            panelID: UUID(uuidString: "31100000-0000-0000-0000-000000000001")!,
            tmuxSession: "main",
            targetKey: target
        )
        let second = UniConnectSSHReconnectPolicy.Candidate(
            workspaceID: UUID(uuidString: "21100000-0000-0000-0000-000000000002")!,
            panelID: UUID(uuidString: "31100000-0000-0000-0000-000000000002")!,
            tmuxSession: "main",
            targetKey: target
        )

        #expect(
            UniConnectSSHReconnectPolicy.canonicalOwner(
                for: target,
                in: [second, first]
            ) == first.owner
        )
    }

    @Test("Creating or reopening an SSH window reports the existing global target owner")
    func duplicateSSHTargetFindsDeterministicOwnerOutsideTheCurrentBox() throws {
        let target = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@example.test",
                port: 22,
                tmuxSession: "main"
            )
        )
        let first = UniConnectSSHReconnectPolicy.Candidate(
            workspaceID: UUID(uuidString: "22000000-0000-0000-0000-000000000001")!,
            panelID: UUID(uuidString: "32000000-0000-0000-0000-000000000001")!,
            tmuxSession: "main",
            targetKey: target
        )
        let second = UniConnectSSHReconnectPolicy.Candidate(
            workspaceID: UUID(uuidString: "22000000-0000-0000-0000-000000000002")!,
            panelID: UUID(uuidString: "32000000-0000-0000-0000-000000000002")!,
            tmuxSession: "main",
            targetKey: target
        )

        #expect(
            UniConnectSSHReconnectPolicy.conflictingCandidate(
                for: target,
                excluding: [],
                in: [second, first]
            ) == first
        )
        #expect(
            UniConnectSSHReconnectPolicy.conflictingCandidate(
                for: target,
                excluding: [first.owner, second.owner],
                in: [second, first]
            ) == nil
        )
    }

    @Test("SSH target ownership distinguishes user, port, host, and tmux session")
    func sshTargetKeyUsesCompleteSecretFreeEndpointIdentity() throws {
        let baseline = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@[2001:DB8::1]",
                port: nil,
                tmuxSession: "main"
            )
        )
        let equivalent = try #require(
            UniConnectSSHTargetKey(
                destination: "deploy@2001:db8::1",
                port: 22,
                tmuxSession: "main"
            )
        )
        #expect(baseline == equivalent)
        #expect(
            baseline != UniConnectSSHTargetKey(
                destination: "root@2001:db8::1",
                port: 22,
                tmuxSession: "main"
            )
        )
        #expect(
            baseline != UniConnectSSHTargetKey(
                destination: "deploy@2001:db8::1",
                port: 2222,
                tmuxSession: "main"
            )
        )
        #expect(
            baseline != UniConnectSSHTargetKey(
                destination: "deploy@other.example",
                port: 22,
                tmuxSession: "main"
            )
        )
        #expect(
            baseline != UniConnectSSHTargetKey(
                destination: "deploy@2001:db8::1",
                port: 22,
                tmuxSession: "logs"
            )
        )
    }

    @Test("SSH respawn never inherits a remote cwd as a local PTY directory")
    func sshRespawnDisablesExistingWorkingDirectoryInheritance() {
        #expect(
            Workspace.respawnWorkingDirectory(
                explicit: nil,
                panelDirectory: "/srv/remote/project",
                previousRequestedDirectory: "/opt/remote/previous",
                workspaceDirectory: "/var/lib/remote/workspace",
                inheritExistingWorkingDirectory: false
            ) == nil
        )
        #expect(
            Workspace.respawnWorkingDirectory(
                explicit: "/Users/test/Local",
                panelDirectory: "/srv/remote/project",
                previousRequestedDirectory: nil,
                workspaceDirectory: nil,
                inheritExistingWorkingDirectory: false
            ) == "/Users/test/Local"
        )
        #expect(
            Workspace.respawnWorkingDirectory(
                explicit: nil,
                panelDirectory: "/Users/test/Inherited",
                previousRequestedDirectory: nil,
                workspaceDirectory: nil,
                inheritExistingWorkingDirectory: true
            ) == "/Users/test/Inherited"
        )
    }

    @Test("SSH credential edit preflights all windows and leaves closed history on revision A")
    @MainActor
    func credentialEditUsesImmutableRevisionAndCommitsAllWindowsTogether() async throws {
        let executor = SSHCredentialEditExecutorStub()
        let transaction = UniConnectSSHCredentialEditTransaction(executor: executor)
        let workspaceID = UUID()
        let oldID = UUID()
        let newID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let windows = [
            UniConnectSSHCredentialEditTransaction.Window(
                workspaceID: workspaceID,
                panelID: firstPanelID,
                tmuxSession: "app"
            ),
            UniConnectSSHCredentialEditTransaction.Window(
                workspaceID: workspaceID,
                panelID: secondPanelID,
                tmuxSession: "logs"
            ),
        ]
        var profileCredentialID = oldID
        var liveCredentialIDs = [firstPanelID: oldID, secondPanelID: oldID]
        let closedHistoryCredentialID = oldID
        var stored = [oldID: "ssh deploy@a.example"]
        var persistCount = 0

        let result = try await transaction.execute(
            oldCredentialID: oldID,
            newConnectCommand: "ssh deploy@b.example",
            windows: windows,
            conflictingTarget: { _, _ in nil },
            createCredentialRevision: { command in
                stored[newID] = command
                return newID
            },
            removeCredentialRevision: { stored.removeValue(forKey: $0) },
            commit: { credentialID, _, editedWindows in
                profileCredentialID = credentialID
                for window in editedWindows {
                    liveCredentialIDs[window.panelID] = credentialID
                }
                return true
            },
            rollback: { credentialID, editedWindows in
                profileCredentialID = credentialID
                for window in editedWindows {
                    liveCredentialIDs[window.panelID] = credentialID
                }
                return true
            },
            persist: { persistCount += 1 }
        )

        #expect(result == newID)
        #expect(profileCredentialID == newID)
        #expect(Set(liveCredentialIDs.values) == [newID])
        #expect(closedHistoryCredentialID == oldID)
        #expect(stored[oldID] == "ssh deploy@a.example")
        #expect(stored[newID] == "ssh deploy@b.example")
        #expect(persistCount == 1)
        let checkedSessions = await executor.checkedTmuxSessions()
        #expect(checkedSessions == ["app", "logs"])
    }

    @Test("A partial SSH credential edit rolls every window and vault reference back to A")
    @MainActor
    func credentialEditFailureRollsBackProfileWindowsAndNewRevision() async throws {
        let executor = SSHCredentialEditExecutorStub()
        let transaction = UniConnectSSHCredentialEditTransaction(executor: executor)
        let workspaceID = UUID()
        let oldID = UUID()
        let newID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let windows = [
            UniConnectSSHCredentialEditTransaction.Window(
                workspaceID: workspaceID,
                panelID: firstPanelID,
                tmuxSession: "app"
            ),
            UniConnectSSHCredentialEditTransaction.Window(
                workspaceID: workspaceID,
                panelID: secondPanelID,
                tmuxSession: "logs"
            ),
        ]
        var profileCredentialID = oldID
        var liveCredentialIDs = [firstPanelID: oldID, secondPanelID: oldID]
        var stored = [oldID: "ssh deploy@a.example"]
        var persistCount = 0

        do {
            _ = try await transaction.execute(
                oldCredentialID: oldID,
                newConnectCommand: "ssh deploy@b.example",
                windows: windows,
                conflictingTarget: { _, _ in nil },
                createCredentialRevision: { command in
                    stored[newID] = command
                    return newID
                },
                removeCredentialRevision: { stored.removeValue(forKey: $0) },
                commit: { credentialID, _, editedWindows in
                    profileCredentialID = credentialID
                    liveCredentialIDs[editedWindows[0].panelID] = credentialID
                    return false
                },
                rollback: { credentialID, editedWindows in
                    profileCredentialID = credentialID
                    for window in editedWindows {
                        liveCredentialIDs[window.panelID] = credentialID
                    }
                    return true
                },
                persist: { persistCount += 1 }
            )
            Issue.record("Expected the simulated partial respawn to fail")
        } catch let failure as UniConnectSSHCredentialEditTransaction.Failure {
            #expect(failure == .commitFailed)
        }

        #expect(profileCredentialID == oldID)
        #expect(Set(liveCredentialIDs.values) == [oldID])
        #expect(stored == [oldID: "ssh deploy@a.example"])
        #expect(persistCount == 1)
    }

    @Test("A failed runtime rollback keeps revision B resolvable for partially migrated windows")
    @MainActor
    func credentialEditRollbackFailureRetainsNewCredentialRevision() async throws {
        let transaction = UniConnectSSHCredentialEditTransaction(
            executor: SSHCredentialEditExecutorStub()
        )
        let oldID = UUID()
        let newID = UUID()
        let panelID = UUID()
        let window = UniConnectSSHCredentialEditTransaction.Window(
            workspaceID: UUID(),
            panelID: panelID,
            tmuxSession: "app"
        )
        var stored = [oldID: "ssh deploy@a.example"]
        var liveCredentialID = oldID
        var removeWasCalled = false
        var persistCount = 0

        do {
            _ = try await transaction.execute(
                oldCredentialID: oldID,
                newConnectCommand: "ssh deploy@b.example",
                windows: [window],
                conflictingTarget: { _, _ in nil },
                createCredentialRevision: { command in
                    stored[newID] = command
                    return newID
                },
                removeCredentialRevision: { id in
                    removeWasCalled = true
                    stored.removeValue(forKey: id)
                },
                commit: { credentialID, _, _ in
                    liveCredentialID = credentialID
                    return false
                },
                rollback: { _, _ in false },
                persist: { persistCount += 1 }
            )
            Issue.record("Expected the failed runtime rollback to be reported")
        } catch let failure as UniConnectSSHCredentialEditTransaction.Failure {
            #expect(failure == .rollbackFailed)
        }

        #expect(liveCredentialID == newID)
        #expect(stored[oldID] == "ssh deploy@a.example")
        #expect(stored[newID] == "ssh deploy@b.example")
        #expect(!removeWasCalled)
        #expect(persistCount == 1)
    }

    @Test("A failed durable rollback keeps revision B for any B-bound snapshot on disk")
    @MainActor
    func credentialEditRollbackPersistenceFailureRetainsNewCredentialRevision() async throws {
        let transaction = UniConnectSSHCredentialEditTransaction(
            executor: SSHCredentialEditExecutorStub()
        )
        let oldID = UUID()
        let newID = UUID()
        let panelID = UUID()
        let window = UniConnectSSHCredentialEditTransaction.Window(
            workspaceID: UUID(),
            panelID: panelID,
            tmuxSession: "app"
        )
        var stored = [oldID: "ssh deploy@a.example"]
        var liveCredentialID = oldID
        var removeWasCalled = false
        var persistCount = 0

        do {
            _ = try await transaction.execute(
                oldCredentialID: oldID,
                newConnectCommand: "ssh deploy@b.example",
                windows: [window],
                conflictingTarget: { _, _ in nil },
                createCredentialRevision: { command in
                    stored[newID] = command
                    return newID
                },
                removeCredentialRevision: { id in
                    removeWasCalled = true
                    stored.removeValue(forKey: id)
                },
                commit: { credentialID, _, _ in
                    liveCredentialID = credentialID
                    return true
                },
                rollback: { credentialID, _ in
                    liveCredentialID = credentialID
                    return true
                },
                persist: {
                    persistCount += 1
                    throw UniConnectSSHCredentialEditTransaction.Failure.persistenceFailed
                }
            )
            Issue.record("Expected the failed durable rollback to be reported")
        } catch let failure as UniConnectSSHCredentialEditTransaction.Failure {
            #expect(failure == .rollbackFailed)
        }

        #expect(liveCredentialID == oldID)
        #expect(stored[oldID] == "ssh deploy@a.example")
        #expect(stored[newID] == "ssh deploy@b.example")
        #expect(!removeWasCalled)
        #expect(persistCount == 2)
    }

    @Test("SSH credential edit rejects a target already owned in another box before mutation")
    @MainActor
    func credentialEditRejectsCrossBoxTargetConflict() async throws {
        let executor = SSHCredentialEditExecutorStub()
        let transaction = UniConnectSSHCredentialEditTransaction(executor: executor)
        let window = UniConnectSSHCredentialEditTransaction.Window(
            workspaceID: UUID(),
            panelID: UUID(),
            tmuxSession: "main"
        )
        var didCreateCredential = false

        do {
            _ = try await transaction.execute(
                oldCredentialID: UUID(),
                newConnectCommand: "ssh deploy@example.test",
                windows: [window],
                conflictingTarget: { targets, _ in targets.first },
                createCredentialRevision: { _ in
                    didCreateCredential = true
                    return UUID()
                },
                removeCredentialRevision: { _ in },
                commit: { _, _, _ in true },
                rollback: { _, _ in true },
                persist: {}
            )
            Issue.record("Expected the globally-owned tmux target to be rejected")
        } catch let failure as UniConnectSSHCredentialEditTransaction.Failure {
            guard case .duplicateTarget(let target) = failure else {
                Issue.record("Expected duplicateTarget, got \(failure)")
                return
            }
            #expect(target.username == "deploy")
            #expect(target.host == "example.test")
            #expect(target.port == 22)
            #expect(target.tmuxSession == "main")
        }

        #expect(!didCreateCredential)
        let checkedSessions = await executor.checkedTmuxSessions()
        #expect(checkedSessions.isEmpty)
    }

    @Test("Restore grants one global owner when two workspaces reference the same active session")
    func duplicateRestoreClaimsKeepFirstOwnerAndPreserveSecondHistory() throws {
        let firstWorkspaceID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let secondWorkspaceID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        let firstPanelID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let secondPanelID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let sharedSessionID = "shared-codex-thread"
        let firstRecord = activeRecord(
            id: firstPanelID,
            root: "/tmp/first-box",
            sessionID: sharedSessionID
        )
        let secondRecord = activeRecord(
            id: secondPanelID,
            root: "/tmp/second-box",
            sessionID: sharedSessionID
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 100,
            windows: [
                restoreWindow(
                    workspaceID: firstWorkspaceID,
                    panelID: firstPanelID,
                    record: firstRecord
                ),
                restoreWindow(
                    workspaceID: secondWorkspaceID,
                    panelID: secondPanelID,
                    record: secondRecord
                ),
            ]
        )

        let resolved = UniConnectLocalAgentRestoreClaimPolicy
            .resolvingDuplicateAutomaticClaims(in: snapshot)
        let first = try #require(resolved.windows[0].tabManager.workspaces[0].panels[0].terminal)
        let second = try #require(resolved.windows[1].tabManager.workspaces[0].panels[0].terminal)

        #expect(first.uniConnectLocalWindow?.runtimeState == .agent)
        #expect(first.wasAgentRunning == true)
        #expect(second.uniConnectLocalWindow?.runtimeState == .shell)
        #expect(second.wasAgentRunning == false)
        #expect(second.hibernation == nil)
        #expect(second.resumeBinding == nil)
        #expect(second.agent?.sessionId == sharedSessionID)
        #expect(second.uniConnectLocalWindow?.conversations.count == 1)

        let requestedClaim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .codex,
                sessionID: sharedSessionID
            )
        )
        let conflict = UniConnectLocalAgentRestoreClaimPolicy.conflictingActiveOwner(
            for: requestedClaim,
            requester: .init(workspaceID: secondWorkspaceID, panelID: secondPanelID),
            candidates: [
                .init(
                    owner: .init(workspaceID: firstWorkspaceID, panelID: firstPanelID),
                    record: firstRecord
                ),
                .init(
                    owner: .init(workspaceID: secondWorkspaceID, panelID: secondPanelID),
                    record: secondRecord
                ),
            ]
        )
        #expect(conflict == .init(workspaceID: firstWorkspaceID, panelID: firstPanelID))
    }

    @Test("UUID-shaped claims canonicalize case while opaque provider IDs remain case-sensitive")
    func claimCanonicalizationMatchesProviderIdentityRules() throws {
        let uppercase = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercase = uppercase.lowercased()
        let first = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .claude, sessionID: uppercase)
        )
        let second = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .claude, sessionID: lowercase)
        )
        #expect(first == second)
        #expect(first.sessionID == lowercase)

        let opaqueUpper = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .codex, sessionID: "Thread-A")
        )
        let opaqueLower = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .codex, sessionID: "thread-a")
        )
        #expect(opaqueUpper != opaqueLower)

        let liveRegistryAgy = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .custom("antigravity"),
                sessionID: "agy-conversation"
            )
        )
        let decodedAgy = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .antigravity,
                sessionID: "agy-conversation"
            )
        )
        #expect(liveRegistryAgy == decodedAgy)
    }

    @Test("A pending delivery owns the claim and stale generations cannot release its successor")
    @MainActor
    func pendingClaimIsGloballySingleFlight() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let claim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .claude,
                sessionID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
            )
        )
        let firstOwner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let secondOwner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let firstLease = try #require(registry.reserve(claim, for: firstOwner))
        let otherClaim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .codex,
                sessionID: "another-thread"
            )
        )

        #expect(registry.reserve(claim, for: secondOwner) == nil)
        #expect(registry.reserve(otherClaim, for: firstOwner) == nil)
        #expect(registry.conflictingOwner(for: claim, requester: secondOwner) == firstOwner)
        #expect(registry.markDelivered(firstLease))
        #expect(registry.markDelivered(firstLease))
        #expect(registry.phase(for: firstLease) == .awaitingCommand)
        #expect(registry.release(firstLease))

        let secondLease = try #require(registry.reserve(claim, for: secondOwner))
        #expect(!registry.release(firstLease))
        #expect(registry.markActive(secondLease))
        #expect(registry.phase(for: secondLease) == .active)
    }

    @Test("An exact observation replaces stale ownership left by a delayed prompt-idle signal")
    @MainActor
    func observedManualSwitchReplacesStaleOwnerClaim() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let claude = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .claude,
                sessionID: "claude-before-fast-switch"
            )
        )
        let codex = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .codex,
                sessionID: "codex-after-fast-switch"
            )
        )
        let owner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let staleLease = try #require(registry.registerActive(claude, for: owner))

        let observedLease = try #require(
            registry.registerObserved(codex, for: owner, replacing: nil)
        )

        #expect(registry.phase(for: staleLease) == nil)
        #expect(registry.phase(for: observedLease) == .active)
        #expect(registry.claimedConversations == [codex])
    }

    @Test("A delayed shell-idle notification cannot tear down a newer agent")
    @MainActor
    func staleShellActivitySignalsAreRejected() {
        #expect(
            !UniConnectCoordinator.isCurrentLocalAgentShellActivitySignal(
                Workspace.PanelShellActivityState.promptIdle.rawValue,
                currentState: .commandRunning,
                runtimeState: .agent
            )
        )
        // Process observation can precede the shell integration's command-running event.
        #expect(
            !UniConnectCoordinator.isCurrentLocalAgentShellActivitySignal(
                Workspace.PanelShellActivityState.promptIdle.rawValue,
                currentState: .promptIdle,
                runtimeState: .agent
            )
        )
        #expect(
            UniConnectCoordinator.isCurrentLocalAgentShellActivitySignal(
                Workspace.PanelShellActivityState.commandRunning.rawValue,
                currentState: .commandRunning,
                runtimeState: .agent
            )
        )
        #expect(
            UniConnectCoordinator.isCurrentLocalAgentShellActivitySignal(
                Workspace.PanelShellActivityState.promptIdle.rawValue,
                currentState: .promptIdle,
                runtimeState: .shell
            )
        )
        #expect(
            !UniConnectCoordinator.isCurrentLocalAgentShellActivitySignal(
                nil,
                currentState: .commandRunning
            )
        )
    }

    @Test("Delivery and command-observation failures release the exact pending generation")
    @MainActor
    func failedLaunchPhasesReleaseClaimForVisibleManualRecovery() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let claim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .codex,
                sessionID: "delivery-timeout-thread"
            )
        )
        let owner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let deliveryLease = try #require(registry.reserve(claim, for: owner))

        // Surface-never-ready timeout.
        #expect(registry.phase(for: deliveryLease) == .pendingDelivery)
        #expect(registry.release(deliveryLease))

        // Input delivered, but no commandRunning signal arrived before the second timeout.
        let commandLease = try #require(registry.reserve(claim, for: owner))
        #expect(registry.markDelivered(commandLease))
        #expect(registry.phase(for: commandLease) == .awaitingCommand)
        #expect(registry.release(commandLease))
        #expect(registry.claimedConversations.isEmpty)
    }

    @Test("Active reconciliation prunes exited owners while preserving in-flight delivery")
    @MainActor
    func claimReconciliationDoesNotStealPendingDelivery() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let pendingClaim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .claude, sessionID: "pending")
        )
        let staleClaim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .codex, sessionID: "stale")
        )
        let pendingOwner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let staleOwner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let pendingLease = try #require(registry.reserve(pendingClaim, for: pendingOwner))
        _ = try #require(registry.registerActive(staleClaim, for: staleOwner))

        registry.reconcileActive([:])

        #expect(registry.phase(for: pendingLease) == .pendingDelivery)
        #expect(registry.claimedConversations == [pendingClaim])
    }

    @Test("A newly discovered agent claim is idempotent for its owner and rejects another owner")
    @MainActor
    func discoveredActiveClaimCannotAcquireTwoOwners() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let claim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(
                kind: .antigravity,
                sessionID: "agy-session"
            )
        )
        let owner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let other = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )

        let first = try #require(registry.registerActive(claim, for: owner))
        #expect(registry.registerActive(claim, for: owner) == first)
        #expect(registry.phase(for: first) == .active)
        #expect(registry.registerActive(claim, for: other) == nil)
        #expect(registry.conflictingOwner(for: claim, requester: other) == owner)
    }

    @Test("An observed claim replaces only its own mismatched launch reservation")
    @MainActor
    func observedClaimReplacesMismatchedReservation() throws {
        let registry = UniConnectLocalAgentClaimRegistry()
        let reserved = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .claude, sessionID: "reserved-session")
        )
        let observed = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .antigravity, sessionID: "observed-session")
        )
        let owner = UniConnectLocalAgentRestoreClaimPolicy.Owner(
            workspaceID: UUID(),
            panelID: UUID()
        )
        let lease = try #require(registry.reserve(reserved, for: owner))
        #expect(registry.markDelivered(lease))

        let observedLease = try #require(
            registry.registerObserved(observed, for: owner, replacing: lease)
        )

        #expect(registry.phase(for: lease) == nil)
        #expect(registry.phase(for: observedLease) == .active)
        #expect(registry.claimedConversations == [observed])
    }

    @Test("A rejected duplicate remains recoverable without appearing live")
    func rejectedDuplicateBecomesManualRecoveryHistory() throws {
        let root = "/Users/test/repository"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "shared-codex-session",
            workingDirectory: root
        )
        var record = UniConnectLocalWindowRecord(boxRoot: root)

        let remembered = record.rememberForManualRecovery(snapshot, at: 123)
        #expect(remembered)
        #expect(record.runtimeState == .shell)
        #expect(record.activeConversation == nil)
        #expect(record.latestConversation?.sessionID == "shared-codex-session")
        let emptyRegistry = CmuxVaultAgentRegistry(registrations: [])
        #expect(record.latestRestorableSnapshot(registry: emptyRegistry)?.sessionId == "shared-codex-session")
    }

    @Test("Closed-history restore resolves against claims already owned by live windows")
    func seededRestoreClaimKeepsIncomingWindowAsRecoverableShell() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "shared-live-owner"
        let record = activeRecord(id: panelID, root: "/tmp/recovered-box", sessionID: sessionID)
        let incoming = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 100,
            windows: [restoreWindow(workspaceID: workspaceID, panelID: panelID, record: record)]
        )
        let liveClaim = try #require(
            UniConnectLocalAgentRestoreClaimPolicy.claim(kind: .codex, sessionID: sessionID)
        )

        let resolved = UniConnectLocalAgentRestoreClaimPolicy.resolvingDuplicateAutomaticClaims(
            in: incoming,
            alreadyClaimed: [liveClaim]
        )
        let terminal = try #require(
            resolved.windows.first?.tabManager.workspaces.first?.panels.first?.terminal
        )

        #expect(terminal.uniConnectLocalWindow?.runtimeState == .shell)
        #expect(terminal.wasAgentRunning == false)
        #expect(terminal.hibernation == nil)
        #expect(terminal.resumeBinding == nil)
        #expect(terminal.uniConnectLocalWindow?.latestConversation?.sessionID == sessionID)
    }

    private func localRecord(
        root: String = "/Users/test/repository",
        workingDirectory: String? = nil
    ) -> UniConnectLocalWindowRecord {
        UniConnectLocalWindowRecord(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
            visibleName: "Work",
            boxRoot: root,
            workingDirectory: workingDirectory,
            createdAt: 10,
            updatedAt: 10
        )
    }

    private func snapshot(
        _ kind: RestorableAgentKind,
        sessionID: String
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: "/tmp/observed-cwd",
            launchCommand: nil
        )
    }

    private func activeRecord(
        id: UUID,
        root: String,
        sessionID: String
    ) -> UniConnectLocalWindowRecord {
        var record = UniConnectLocalWindowRecord(
            id: id,
            visibleName: "Codex",
            boxRoot: root,
            createdAt: 100,
            updatedAt: 100
        )
        _ = record.record(snapshot(.codex, sessionID: sessionID), at: 101)
        return record
    }

    private func restoreWindow(
        workspaceID: UUID,
        panelID: UUID,
        record: UniConnectLocalWindowRecord
    ) -> SessionWindowSnapshot {
        let agent = record.latestRestorableSnapshot(registry: emptyRegistry)
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: record.workingDirectory,
            agent: agent,
            hibernation: SessionAgentHibernationSnapshot(
                hibernatedAt: 102,
                lastActivityAt: 102
            ),
            wasAgentRunning: true,
            uniConnectLocalWindow: record
        )
        let panel = SessionPanelSnapshot(
            id: panelID,
            type: .terminal,
            title: "Codex",
            customTitle: "Codex",
            directory: record.workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: terminal,
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let workspace = SessionWorkspaceSnapshot(
            workspaceId: workspaceID,
            processTitle: "Box",
            customTitle: "Box",
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: record.boxRoot,
            focusedPanelId: panelID,
            layout: .pane(
                SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)
            ),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil,
            uniConnect: UniConnectWorkspaceProfile(
                kind: .local,
                importIdentity: workspaceID,
                localRoot: record.boxRoot
            )
        )
        return SessionWindowSnapshot(
            windowId: UUID(),
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: 240
            )
        )
    }

    private actor SSHCredentialEditExecutorStub: UniConnectSSHCommandExecuting {
        private var sessions: [String] = []

        func execute(
            _ invocation: UniConnectSSHProcessInvocation,
            timeout: Duration
        ) async throws {
            _ = timeout
            if let remoteCommand = invocation.arguments.last,
               let marker = remoteCommand.range(of: "tmux has-session -t '") {
                let suffix = remoteCommand[marker.upperBound...]
                if let end = suffix.firstIndex(of: "'") {
                    sessions.append(String(suffix[..<end]))
                }
            }
        }

        func checkedTmuxSessions() -> [String] {
            sessions
        }
    }
}
