import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect persistent local windows")
struct UniConnectLocalWindowRecordTests {
    private let emptyRegistry = CmuxVaultAgentRegistry(registrations: [])

    @Test("Switching agents appends history and makes the newest conversation resumable")
    func switchingAgentsPreservesEveryConversation() throws {
        var record = UniConnectLocalWindowRecord(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            visibleName: "Implementation",
            boxRoot: "/Users/test/Projects/Box Root",
            createdAt: 100,
            updatedAt: 100
        )
        let claude = agent(.claude, sessionID: "20000000-0000-0000-0000-000000000001")
        let codex = agent(.codex, sessionID: "codex-thread-1")
        let agy = agent(.antigravity, sessionID: "agy-conversation-1")

        let recordedClaude = record.record(claude, at: 101)
        #expect(recordedClaude)
        let leftClaude = record.transitionToShell(at: 102)
        #expect(leftClaude)
        let recordedCodex = record.record(codex, at: 103)
        #expect(recordedCodex)
        let leftCodex = record.transitionToShell(at: 104)
        #expect(leftCodex)
        let recordedAgy = record.record(agy, at: 105)
        #expect(recordedAgy)

        #expect(record.conversations.map(\.kind) == [.claude, .codex, .antigravity])
        #expect(record.latestConversation?.sessionID == "agy-conversation-1")
        #expect(record.activeConversation?.sessionID == "agy-conversation-1")
        #expect(record.runtimeState == .agent)
        let resume = try #require(record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand)
        #expect(resume.contains("agy"))
        #expect(resume.contains("--conversation"))
        #expect(resume.contains("--dangerously-skip-permissions"))
        #expect(resume.contains("/Users/test/Projects/Box Root"))
    }

    @Test("Returning to shell or stopping never drops the saved conversation")
    func shellAndStoppedStatesRetainLatestConversation() throws {
        var record = UniConnectLocalWindowRecord(
            visibleName: "Review",
            boxRoot: "/Users/test/repository",
            createdAt: 200,
            updatedAt: 200
        )
        let recordedCodex = record.record(agent(.codex, sessionID: "codex-thread-2"), at: 201)
        #expect(recordedCodex)
        let latestID = try #require(record.latestConversationID)

        let transitionedToShell = record.transitionToShell(at: 202)
        #expect(transitionedToShell)
        #expect(record.runtimeState == .shell)
        #expect(record.activeConversationID == nil)
        #expect(record.latestConversationID == latestID)
        #expect(record.conversations.count == 1)

        let markedStopped = record.markStopped(at: 203)
        #expect(markedStopped)
        #expect(record.runtimeState == .stopped)
        #expect(record.latestConversationID == latestID)
        #expect(record.conversations.count == 1)
        let resume = try #require(record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand)
        #expect(resume.contains("codex"))
        #expect(resume.contains("resume"))
        #expect(resume.contains("--yolo"))
    }

    @Test("UUID-shaped session identifiers deduplicate independent of letter case")
    func uuidSessionIdentityIsCanonical() throws {
        let uppercase = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercase = uppercase.lowercased()
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 250,
            updatedAt: 250
        )

        let recordedUppercase = record.record(agent(.claude, sessionID: uppercase), at: 251)
        #expect(recordedUppercase)
        let originalID = try #require(record.latestConversationID)
        let transitionedToShell = record.transitionToShell(at: 252)
        #expect(transitionedToShell)
        let recordedLowercase = record.record(agent(.claude, sessionID: lowercase), at: 253)
        #expect(recordedLowercase)

        #expect(record.conversations.count == 1)
        #expect(record.latestConversationID == originalID)
        #expect(record.activeConversationID == originalID)
    }

    @Test("Conversation UUIDs remain unique and duplicated imported UUIDs fail closed")
    func conversationUUIDsCannotBeDuplicated() throws {
        let repeatedID = UUID(uuidString: "26000000-0000-0000-0000-000000000001")!
        let first = try #require(UniConnectLocalAgentConversation(
            id: repeatedID,
            kind: .claude,
            sessionID: "26000000-0000-0000-0000-000000000002",
            firstSeenAt: 1
        ))
        let second = try #require(UniConnectLocalAgentConversation(
            id: repeatedID,
            kind: .codex,
            sessionID: "codex-thread-with-repeated-id",
            firstSeenAt: 2
        ))

        let record = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            conversations: [first, second],
            createdAt: 1,
            updatedAt: 2
        )
        #expect(record.conversations.count == 2)
        #expect(record.conversations.map(\.identityKey) == [first.identityKey, second.identityKey])
        #expect(record.conversations.first?.id == repeatedID)
        #expect(record.conversations.last?.id != repeatedID)
        #expect(Set(record.conversations.map(\.id)).count == record.conversations.count)

        var merged = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            conversations: [first],
            createdAt: 1,
            updatedAt: 1
        )
        let incoming = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            conversations: [second],
            createdAt: 1,
            updatedAt: 2
        )
        let didMerge = merged.mergeImportedStatePreservingHistory(incoming, at: 3)
        #expect(didMerge)
        #expect(merged.conversations.map(\.identityKey) == [first.identityKey, second.identityKey])
        #expect(Set(merged.conversations.map(\.id)).count == merged.conversations.count)
        #expect(merged.latestConversation?.identityKey == second.identityKey)

        let importedObject: [String: Any] = [
            "version": 2,
            "id": "26000000-0000-0000-0000-000000000003",
            "boxRoot": "/repo",
            "workingDirectory": "/repo",
            "runtimeState": "shell",
            "conversations": [
                [
                    "id": repeatedID.uuidString,
                    "kind": "claude",
                    "sessionID": "26000000-0000-0000-0000-000000000002",
                    "displayName": "Claude",
                    "firstSeenAt": 1,
                ],
                [
                    "id": repeatedID.uuidString,
                    "kind": "codex",
                    "sessionID": "codex-thread-with-repeated-id",
                    "displayName": "Codex",
                    "firstSeenAt": 2,
                ],
            ],
            "createdAt": 1,
            "updatedAt": 2,
        ]
        let importedData = try JSONSerialization.data(withJSONObject: importedObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: importedData)
        }
    }

    @Test("Only agent commands require an idle live shell")
    func foregroundAgentCommandsRequireIdleShellPrompt() {
        let conversationID = UUID()

        #expect(UniConnectLocalWindowAction.resumeConversation(conversationID).requiresIdleShellPrompt)
        #expect(UniConnectLocalWindowAction.startAgent(.claude).requiresIdleShellPrompt)
        #expect(UniConnectLocalWindowAction.startAgent(.codex).requiresIdleShellPrompt)
        #expect(UniConnectLocalWindowAction.startAgent(.agy).requiresIdleShellPrompt)
        #expect(UniConnectLocalWindowAction.startAgent(.grok).requiresIdleShellPrompt)
        #expect(!UniConnectLocalWindowAction.startAgent(.terminal).requiresIdleShellPrompt)
        #expect(!UniConnectLocalWindowAction.reopenTerminal.requiresIdleShellPrompt)
        #expect(!UniConnectLocalWindowAction.forgetConversation(conversationID).requiresIdleShellPrompt)

        let resume = UniConnectLocalWindowAction.resumeConversation(conversationID)
        #expect(!resume.canDispatchForegroundCommand(runtimeState: .shell, shellIsAtPrompt: false))
        #expect(resume.canDispatchForegroundCommand(runtimeState: .shell, shellIsAtPrompt: true))
        #expect(resume.canDispatchForegroundCommand(runtimeState: .stopped, shellIsAtPrompt: false))
        #expect(!resume.canDispatchForegroundCommand(runtimeState: .agent, shellIsAtPrompt: true))

        let terminal = UniConnectLocalWindowAction.startAgent(.terminal)
        #expect(terminal.canDispatchForegroundCommand(runtimeState: .shell, shellIsAtPrompt: false))
    }

    @Test("Only explicit forget removes a conversation and falls back to prior history")
    func explicitForgetIsTheOnlyDestructiveTransition() throws {
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 300,
            updatedAt: 300
        )
        _ = record.record(agent(.claude, sessionID: "30000000-0000-0000-0000-000000000001"), at: 301)
        _ = record.transitionToShell(at: 302)
        _ = record.record(agent(.grok, sessionID: "grok-session-1"), at: 303)
        let grokID = try #require(record.latestConversationID)
        let grokResume = try #require(
            record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand
        )
        #expect(grokResume.contains("'grok' '-r' 'grok-session-1'"))

        let forgotGrok = record.forgetConversation(id: grokID, at: 304)
        #expect(forgotGrok)
        #expect(record.conversations.count == 1)
        #expect(record.latestConversation?.kind == .claude)
        #expect(record.runtimeState == .shell)
        let forgotGrokAgain = record.forgetConversation(id: grokID, at: 305)
        #expect(!forgotGrokAgain)
    }

    @Test("Legacy Claude binding migrates and survives a Codable round trip in shell state")
    func legacyClaudeMigrationRoundTripsWithoutAutoForgetting() throws {
        let sessionID = "40000000-0000-0000-0000-000000000001"
        var record = UniConnectLocalWindowRecord.migratingLegacy(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            visibleName: "Claude review",
            boxRoot: "/Users/test/Legacy Box",
            agent: nil,
            claudeSession: sessionID,
            wasAgentRunning: false,
            timestamp: 400
        )
        #expect(record.runtimeState == .shell)
        #expect(record.legacyClaudeSession == sessionID)
        #expect(record.latestConversation?.kind == .claude)

        let data = try JSONEncoder().encode(record)
        record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)
        #expect(record.runtimeState == .shell)
        #expect(record.latestConversation?.sessionID == sessionID)
        #expect(record.activeConversationID == nil)
    }

    @Test("Version-one local-window records migrate their cwd to the trusted root")
    func versionOneLocalWindowMigratesWorkingDirectory() throws {
        let data = Data(
            #"{"version":1,"id":"41000000-0000-0000-0000-000000000001","visibleName":"API","boxRoot":"/repo","runtimeState":"shell","conversations":[],"createdAt":1,"updatedAt":2}"#.utf8
        )

        let record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)

        #expect(record.version == UniConnectLocalWindowRecord.currentVersion)
        #expect(record.boxRoot == "/repo")
        #expect(record.workingDirectory == "/repo")
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["version"] as? Int == UniConnectLocalWindowRecord.currentVersion)
        #expect(object["workingDirectory"] as? String == "/repo")
    }

    @Test("Version-two conversations inherit the saved window cwd during migration")
    func versionTwoConversationsMigrateResumeWorkingDirectory() throws {
        let data = Data(
            #"{"version":2,"id":"41500000-0000-0000-0000-000000000001","boxRoot":"/repo","workingDirectory":"/repo/api","runtimeState":"shell","conversations":[{"id":"41500000-0000-0000-0000-000000000002","kind":"claude","sessionID":"41500000-0000-0000-0000-000000000003","displayName":"Claude Code","firstSeenAt":1}],"latestConversationID":"41500000-0000-0000-0000-000000000002","createdAt":1,"updatedAt":2}"#.utf8
        )

        let record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)

        #expect(record.version == UniConnectLocalWindowRecord.currentVersion)
        #expect(record.latestConversation?.resumeWorkingDirectory == "/repo/api")
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        let conversations = try #require(encoded["conversations"] as? [[String: Any]])
        #expect(conversations.first?["resumeWorkingDirectory"] as? String == "/repo/api")
    }

    @Test("Every conversation resumes from its own trusted historical cwd")
    func switchingAgentsPreservesPerConversationWorkingDirectories() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-conversation-cwd-\(UUID().uuidString)", isDirectory: true)
        let claudeDirectory = fixture.appendingPathComponent("claude", isDirectory: true)
        let agyDirectory = fixture.appendingPathComponent("agy", isDirectory: true)
        let grokDirectory = fixture.appendingPathComponent("grok", isDirectory: true)
        let shellDirectory = fixture.appendingPathComponent("shell", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for directory in [claudeDirectory, agyDirectory, grokDirectory, shellDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var record = UniConnectLocalWindowRecord(
            boxRoot: fixture.path,
            workingDirectory: claudeDirectory.path,
            createdAt: 1,
            updatedAt: 1
        )
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "42500000-0000-0000-0000-000000000001",
                workingDirectory: claudeDirectory.path
            ),
            at: 2
        )
        let claudeID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 3)
        _ = record.reconcileWorkingDirectory(agyDirectory.path, at: 4)
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .antigravity,
                sessionId: "agy-cwd-history",
                workingDirectory: agyDirectory.path
            ),
            at: 5
        )
        let agyID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 6)
        _ = record.reconcileWorkingDirectory(grokDirectory.path, at: 7)
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: "grok-cwd-history",
                workingDirectory: grokDirectory.path
            ),
            at: 8
        )
        let grokID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 9)
        _ = record.reconcileWorkingDirectory(shellDirectory.path, at: 10)

        let claude = try #require(record.restorableSnapshot(for: claudeID, registry: emptyRegistry))
        let agy = try #require(record.restorableSnapshot(for: agyID, registry: emptyRegistry))
        let grok = try #require(record.restorableSnapshot(for: grokID, registry: emptyRegistry))

        #expect(record.workingDirectory == shellDirectory.path)
        #expect(claude.workingDirectory == claudeDirectory.path)
        #expect(agy.workingDirectory == agyDirectory.path)
        #expect(grok.workingDirectory == grokDirectory.path)
        #expect(claude.resumeCommand?.contains(claudeDirectory.path) == true)
        #expect(agy.resumeCommand?.contains(agyDirectory.path) == true)
        #expect(grok.resumeCommand?.contains(grokDirectory.path) == true)
    }

    @Test("Repeated observations update id-keyed cwd but keep directory-keyed launch cwd")
    func repeatedObservationUsesProviderCWDPolicy() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-cwd-refresh-\(UUID().uuidString)", isDirectory: true)
        let launchDirectory = fixture.appendingPathComponent("launch", isDirectory: true)
        let runtimeDirectory = fixture.appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for directory in [launchDirectory, runtimeDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var record = UniConnectLocalWindowRecord(
            boxRoot: fixture.path,
            workingDirectory: launchDirectory.path,
            createdAt: 1,
            updatedAt: 1
        )
        func observation(
            _ kind: RestorableAgentKind,
            sessionID: String,
            workingDirectory: String
        ) -> SessionRestorableAgentSnapshot {
            SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionID,
                workingDirectory: workingDirectory,
                launchCommand: nil
            )
        }

        _ = record.record(
            observation(
                .claude,
                sessionID: "44500000-0000-0000-0000-000000000001",
                workingDirectory: launchDirectory.path
            ),
            at: 2
        )
        let claudeID = try #require(record.latestConversationID)
        _ = record.record(
            observation(
                .claude,
                sessionID: "44500000-0000-0000-0000-000000000001",
                workingDirectory: runtimeDirectory.path
            ),
            at: 3
        )
        _ = record.transitionToShell(at: 4)
        _ = record.record(
            observation(
                .codex,
                sessionID: "codex-refresh-cwd",
                workingDirectory: launchDirectory.path
            ),
            at: 5
        )
        let codexID = try #require(record.latestConversationID)
        _ = record.record(
            observation(
                .codex,
                sessionID: "codex-refresh-cwd",
                workingDirectory: runtimeDirectory.path
            ),
            at: 6
        )

        let claude = try #require(record.conversations.first { $0.id == claudeID })
        let codex = try #require(record.conversations.first { $0.id == codexID })
        #expect(claude.resumeWorkingDirectory == launchDirectory.path)
        #expect(codex.resumeWorkingDirectory == runtimeDirectory.path)
    }

    @Test("Changing the workspace default preserves every historical conversation folder")
    func changedDefaultRootPreservesHistoricalWorkingDirectory() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-root-change-\(UUID().uuidString)", isDirectory: true)
        let originalRoot = fixture.appendingPathComponent("old", isDirectory: true)
        let replacementRoot = fixture.appendingPathComponent("new", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)

        var record = UniConnectLocalWindowRecord(
            boxRoot: originalRoot.path,
            workingDirectory: originalRoot.path,
            createdAt: 1,
            updatedAt: 1
        )
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "43500000-0000-0000-0000-000000000001",
                workingDirectory: originalRoot.path
            ),
            at: 2
        )
        let claudeID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 3)
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "codex-root-change",
                workingDirectory: originalRoot.path
            ),
            at: 4
        )
        let codexID = try #require(record.latestConversationID)

        _ = record.reconcileIdentity(
            visibleName: "Recovered",
            boxRoot: replacementRoot.path,
            workingDirectory: replacementRoot.path,
            at: 5
        )

        let claude = try #require(record.restorableSnapshot(for: claudeID, registry: emptyRegistry))
        #expect(claude.workingDirectory == originalRoot.path)
        #expect(claude.resumeCommand?.contains(originalRoot.path) == true)
        let codex = try #require(record.restorableSnapshot(for: codexID, registry: emptyRegistry))
        #expect(codex.workingDirectory == originalRoot.path)
        #expect(codex.resumeCommand?.contains(originalRoot.path) == true)
        #expect(codex.resumeCommand?.contains(replacementRoot.path) != true)
    }

    @Test("Switching agents across independent folders preserves native identities and historical cwd")
    func agentSwitchAcrossIndependentFoldersKeepsNativeIdentity() throws {
        var record = UniConnectLocalWindowRecord(
            visibleName: "Mixed agents",
            boxRoot: "/workspace/default",
            workingDirectory: "/projects/claude",
            createdAt: 1
        )
        _ = record.record(SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "44500000-0000-0000-0000-000000000007",
            workingDirectory: "/projects/claude"
        ), at: 2)
        let claudeID = try #require(record.latestConversationID)
        _ = record.transitionToShell(at: 3)
        let changedDirectory = record.reconcileWorkingDirectory("/Volumes/Other Project", at: 4)
        #expect(changedDirectory)
        _ = record.record(SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "native-codex-thread",
            workingDirectory: "/Volumes/Other Project"
        ), at: 5)
        _ = record.transitionToShell(at: 6)
        let decoded = try JSONDecoder().decode(
            UniConnectLocalWindowRecord.self,
            from: JSONEncoder().encode(record)
        )
        #expect(decoded.id == record.id)
        #expect(decoded.boxRoot == "/workspace/default")
        #expect(decoded.workingDirectory == "/Volumes/Other Project")
        #expect(decoded.conversations.map(\.sessionID) == [
            "44500000-0000-0000-0000-000000000007", "native-codex-thread"
        ])
        #expect(decoded.latestConversation?.kind == .codex)
        #expect(decoded.activeConversation == nil)
        #expect(decoded.legacyClaudeSession == nil)
        let previousClaude = try #require(decoded.restorableSnapshot(for: claudeID, registry: emptyRegistry))
        #expect(previousClaude.workingDirectory == "/projects/claude")
        #expect(decoded.latestRestorableSnapshot(registry: emptyRegistry)?.workingDirectory == "/Volumes/Other Project")
    }

    @Test("Manual backup uses the supplied process observation without losing native history or independent cwd")
    @MainActor
    func backupUsesSuppliedProcessDetectedAgentIndex() throws {
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-backup-agent-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.uniConnectIsStarter = false
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: "/workspace/default"
        )
        workspace.setCustomTitle("Independent folder")
        workspace.panelDirectories[panelID] = "/Volumes/Other Project"
        var original = UniConnectLocalWindowRecord(
            id: panelID,
            visibleName: "Mixed agents",
            boxRoot: "/workspace/default",
            workingDirectory: "/Volumes/Other Project",
            createdAt: 1
        )
        let previousClaudeID = "45500000-0000-0000-0000-000000000001"
        _ = original.record(SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: previousClaudeID,
            workingDirectory: "/projects/original-claude"
        ), at: 2)
        _ = original.transitionToShell(at: 3)
        workspace.uniConnectInstallLocalWindowRecord(
            original,
            panelId: panelID,
            visibleName: "Mixed agents",
            at: 3
        )
        let nativeCodexID = "native-process-detected-codex-thread"
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: isolatedHome.path,
            fileManager: .default,
            registry: emptyRegistry,
            detectedSnapshots: [
                .init(workspaceId: workspace.id, panelId: panelID): (
                    snapshot: SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: nativeCodexID,
                        workingDirectory: "/Volumes/Other Project"
                    ),
                    updatedAt: 4,
                    processIDs: [123]
                ),
            ],
            processArgumentsProvider: { _ in nil }
        )

        let document = UniConnectBackup.buildDocument(
            tabManagers: [manager],
            reconcileLiveState: false,
            restorableAgentIndex: index
        )
        let savedWorkspace = try #require(document.workspaces.first)
        let savedWindow = try #require(savedWorkspace.windows.first)
        let saved = try #require(savedWindow.localWindow)
        #expect(savedWorkspace.cwd == "/workspace/default")
        #expect(saved.id == panelID)
        #expect(saved.workingDirectory == "/Volumes/Other Project")
        #expect(savedWindow.cwd == "/Volumes/Other Project")
        #expect(saved.conversations.map(\.sessionID) == [previousClaudeID, nativeCodexID])
        #expect(saved.conversations.first?.resumeWorkingDirectory == "/projects/original-claude")
        #expect(saved.latestConversation?.kind == .codex)
        #expect(saved.activeConversation?.sessionID == nativeCodexID)
        #expect(savedWindow.claudeSession == nil)
        #expect(workspace.uniConnectLocalWindowsByPanelId[panelID] == original)
    }

    @Test("Restoring an active local agent starts its login shell in the independent saved folder")
    @MainActor
    func activeAgentRestoreKeepsDurableLoginShellWorkingDirectory() throws {
        let defaultsKey = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previousSetting = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.set(true, forKey: defaultsKey)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-local-restore-cwd-\(UUID().uuidString)", isDirectory: true)
        let savedDirectory = isolatedHome.appendingPathComponent("Independent Window", isDirectory: true)
        let missingWorkspaceDefault = isolatedHome.appendingPathComponent("Deleted Default", isDirectory: true)
        try FileManager.default.createDirectory(at: savedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        let source = Workspace(workingDirectory: savedDirectory.path)
        source.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(),
            localRoot: missingWorkspaceDefault.path
        )
        let panelID = try #require(source.focusedPanelId)
        var record = UniConnectLocalWindowRecord(
            id: panelID,
            visibleName: "Saved Codex",
            boxRoot: missingWorkspaceDefault.path,
            workingDirectory: savedDirectory.path,
            createdAt: 1
        )
        let nativeSessionID = "native-local-restore-\(UUID().uuidString)"
        let runningAgent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: nativeSessionID,
            workingDirectory: savedDirectory.path
        )
        _ = record.record(runningAgent, at: 2)
        let emptyIndex = RestorableAgentSessionIndex.load(
            homeDirectory: isolatedHome.path,
            fileManager: .default,
            registry: emptyRegistry,
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        var snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: emptyIndex
        )
        let panelIndex = try #require(snapshot.panels.firstIndex(where: { $0.id == panelID }))
        snapshot.panels[panelIndex].terminal?.uniConnectLocalWindow = record
        snapshot.panels[panelIndex].terminal?.agent = runningAgent
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = true

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))
        let startupInput = try #require(panel.surface.initialInput)
        #expect(panel.requestedWorkingDirectory == savedDirectory.path)
        #expect(panel.surface.debugInitialCommand() == nil)
        #expect(startupInput.contains(nativeSessionID))
        #expect(startupInput.contains("'--yolo'"))
        #expect(restored.uniConnectLocalWindowsByPanelId[restoredPanelID]?.workingDirectory == savedDirectory.path)
        #expect(restored.uniConnectLocalWindowsByPanelId[restoredPanelID]?.boxRoot == missingWorkspaceDefault.path)
        #expect(restored.uniConnectLocalWindowsByPanelId[restoredPanelID]?.latestConversation?.sessionID == nativeSessionID)

        // Leaving the AI returns to this same durable shell, not an inherited HOME cwd.
        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .commandRunning)
        restored.updatePanelShellActivityState(panelId: restoredPanelID, state: .promptIdle)
        let afterExit = try #require(restored.uniConnectLocalWindowsByPanelId[restoredPanelID])
        #expect(afterExit.workingDirectory == savedDirectory.path)
        #expect(afterExit.latestConversation?.resumeWorkingDirectory == savedDirectory.path)
        #expect(afterExit.latestConversation?.sessionID == nativeSessionID)
    }

    @Test("Two local windows retain distinct cwd values through document coding")
    func twoWindowWorkingDirectoriesRoundTrip() throws {
        func window(id: String, name: String, cwd: String) -> UniConnectDocument.Window {
            UniConnectDocument.Window(
                name: name,
                tmux: nil,
                claudeSession: nil,
                cwd: cwd,
                isPinned: nil,
                localWindow: UniConnectLocalWindowRecord(
                    id: UUID(uuidString: id)!,
                    visibleName: name,
                    boxRoot: "/repo",
                    workingDirectory: cwd,
                    createdAt: 1,
                    updatedAt: 1
                )
            )
        }
        let document = UniConnectDocument(
            workspaces: [
                .init(
                    name: "Repository",
                    kind: .local,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: "/repo",
                    connect: nil,
                    windows: [
                        window(
                            id: "42000000-0000-0000-0000-000000000001",
                            name: "API",
                            cwd: "/repo/api"
                        ),
                        window(
                            id: "42000000-0000-0000-0000-000000000002",
                            name: "Web",
                            cwd: "/Other Project/web"
                        ),
                    ]
                ),
            ],
            savedAt: Date(timeIntervalSince1970: 1)
        )

        let decoded = try JSONDecoder().decode(
            UniConnectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let windows = try #require(decoded.workspaces.first?.windows)

        #expect(decoded.workspaces.first?.cwd == "/repo")
        #expect(windows.map(\.cwd) == ["/repo/api", "/Other Project/web"])
        #expect(windows.compactMap { $0.localWindow?.workingDirectory } == ["/repo/api", "/Other Project/web"])
        #expect(windows.allSatisfy { $0.localWindow?.boxRoot == "/repo" })
    }

    @Test("Version-one UniConnect documents decode without generic local-window state")
    func versionOneDocumentRemainsDecodable() throws {
        let data = Data(
            #"{"version":1,"app":"UniConnect","savedAt":"2026-01-01T00:00:00Z","workspaces":[{"name":"Legacy","kind":"local","cwd":"/Users/test/legacy","windows":[{"name":"Claude","claudeSession":"40000000-0000-0000-0000-000000000001"}]}]}"#.utf8
        )

        let document = try JSONDecoder().decode(UniConnectDocument.self, from: data)

        #expect(document.version == 1)
        #expect(document.workspaces.first?.windows.first?.localWindow == nil)
        #expect(
            document.workspaces.first?.windows.first?.claudeSession
                == "40000000-0000-0000-0000-000000000001"
        )
    }

    @Test("Custom resume descriptors survive config removal without persisting process secrets")
    func customAgentDescriptorIsDurableAndSecretFree() throws {
        let originalRegistration = CmuxVaultAgentRegistration(
            id: "my-local-agent",
            name: "My Local Agent",
            detect: CmuxVaultAgentDetectRule(processName: "my-local-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: "~/.my-local-agent/sessions"
        )
        let replacementRegistration = CmuxVaultAgentRegistration(
            id: "my-local-agent",
            name: "Changed Agent",
            detect: CmuxVaultAgentDetectRule(processName: "changed-agent"),
            sessionIdSource: .argvOption("--conversation"),
            resumeCommand: "changed-agent --conversation {{sessionId}}",
            cwd: .preserve
        )
        let secret = "must-not-enter-local-window-history"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("my-local-agent"),
            sessionId: "custom-session-1",
            workingDirectory: "/Users/test/repository",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "my-local-agent",
                executablePath: "/private/custom/bin/my-local-agent",
                arguments: ["my-local-agent", "--token", secret],
                workingDirectory: "/Users/test/repository",
                environment: ["CUSTOM_AGENT_TOKEN": secret],
                capturedAt: 1,
                source: "test"
            ),
            registration: originalRegistration
        )
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 1,
            updatedAt: 1
        )

        let didRecordSnapshot = record.record(snapshot, at: 2)
        #expect(didRecordSnapshot)
        #expect(record.latestConversation?.customAgentDescriptor?.version == 1)
        #expect(
            record.latestConversation?.customAgentDescriptor?.registration
                == originalRegistration
        )

        let data = try JSONEncoder().encode(record)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("CUSTOM_AGENT_TOKEN"))
        #expect(!text.contains("--token"))

        let decoded = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)
        let withoutConfig = try #require(
            decoded.latestRestorableSnapshot(registry: emptyRegistry)
        )
        #expect(withoutConfig.registration == originalRegistration)
        #expect(withoutConfig.agentDisplayName == "My Local Agent")
        #expect(
            withoutConfig.resumeCommand?.contains(
                "'my-local-agent' '--resume' 'custom-session-1'"
            ) == true
        )

        let changedRegistry = CmuxVaultAgentRegistry(
            registrations: [replacementRegistration]
        )
        let afterConfigChange = try #require(
            decoded.latestRestorableSnapshot(registry: changedRegistry)
        )
        #expect(afterConfigChange.registration == originalRegistration)
        #expect(afterConfigChange.resumeCommand == withoutConfig.resumeCommand)
        #expect(afterConfigChange.resumeCommand?.contains("changed-agent") != true)
    }

    @Test("A custom conversation option remains safe for durable resume")
    func customConversationOptionIsNotTreatedAsCredentialMaterial() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "conversation-agent",
            name: "Conversation Agent",
            detect: CmuxVaultAgentDetectRule(processName: "conversation-agent"),
            sessionIdSource: .argvOption("--conversation"),
            resumeCommand: "{{executable}} --conversation {{sessionId}}"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("conversation-agent"),
            sessionId: "conversation-123",
            workingDirectory: "/repo",
            launchCommand: nil,
            registration: registration
        )
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            createdAt: 1,
            updatedAt: 1
        )

        let didRecord = record.record(snapshot, at: 2)
        #expect(didRecord)
        #expect(record.latestConversation?.sessionID == "conversation-123")
        #expect(record.latestConversation?.customAgentDescriptor?.registration == registration)
        #expect(
            record.latestRestorableSnapshot(registry: emptyRegistry)?
                .resumeCommand?.contains("'--conversation' 'conversation-123'") == true
        )
    }

    @Test("Credential-bearing custom provider contracts never enter durable history")
    func sensitiveCustomProviderContractsFailClosed() throws {
        let scenarios: [(
            label: String,
            sessionIdSource: CmuxVaultAgentSessionIDSource,
            resumeCommand: String,
            sessionID: String,
            sentinel: String
        )] = [
            (
                "API-key-valued session source",
                .argvOption("--api-key"),
                "{{executable}} --resume {{sessionId}}",
                "captured-api-key-secret",
                "captured-api-key-secret"
            ),
            (
                "token-valued session source",
                .argvOption("--token"),
                "{{executable}} --resume {{sessionId}}",
                "captured-token-secret",
                "captured-token-secret"
            ),
            (
                "password-valued session source",
                .argvOption("--password"),
                "{{executable}} --resume {{sessionId}}",
                "captured-password-secret",
                "captured-password-secret"
            ),
            (
                "secret-valued session source",
                .argvOption("--secret"),
                "{{executable}} --resume {{sessionId}}",
                "captured-secret-value",
                "captured-secret-value"
            ),
            (
                "key-valued session source",
                .argvOption("--key"),
                "{{executable}} --resume {{sessionId}}",
                "captured-key-value",
                "captured-key-value"
            ),
            (
                "credential-valued session source",
                .argvOption("--credential"),
                "{{executable}} --resume {{sessionId}}",
                "captured-credential-value",
                "captured-credential-value"
            ),
            (
                "cookie-valued session source",
                .argvOption("--cookie"),
                "{{executable}} --resume {{sessionId}}",
                "captured-cookie-value",
                "captured-cookie-value"
            ),
            (
                "credential option in resume template",
                .argvOption("--conversation"),
                "{{executable}} --api-key embedded-api-key --conversation {{sessionId}}",
                "ordinary-conversation",
                "embedded-api-key"
            ),
            (
                "credential environment assignment in resume template",
                .argvOption("--conversation"),
                "API_TOKEN=embedded-environment-token {{executable}} --conversation {{sessionId}}",
                "ordinary-conversation",
                "embedded-environment-token"
            ),
            (
                "SSH password wrapper in resume template",
                .argvOption("--conversation"),
                "sshpass -p embedded-ssh-password ssh fixture@example.test {{sessionId}}",
                "ordinary-conversation",
                "embedded-ssh-password"
            ),
            (
                "SSH client in resume template",
                .argvOption("--conversation"),
                "/usr/bin/ssh fixture@example.test {{sessionId}}",
                "ordinary-conversation",
                "fixture@example.test"
            ),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let registration = CmuxVaultAgentRegistration(
                id: "unsafe-agent-\(index)",
                name: "Unsafe Agent \(index)",
                detect: CmuxVaultAgentDetectRule(processName: "unsafe-agent-\(index)"),
                sessionIdSource: scenario.sessionIdSource,
                resumeCommand: scenario.resumeCommand
            )
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .custom(registration.id),
                sessionId: scenario.sessionID,
                workingDirectory: "/repo",
                launchCommand: nil,
                registration: registration
            )
            var record = UniConnectLocalWindowRecord(
                boxRoot: "/repo",
                createdAt: 1,
                updatedAt: 1
            )

            let didRecord = record.record(snapshot, at: 2)
            #expect(!didRecord, "\(scenario.label) must fail closed")
            #expect(record.conversations.isEmpty, "\(scenario.label) retained a conversation")
            #expect(record.latestConversationID == nil)
            #expect(record.activeConversationID == nil)
            let persistedText = String(
                decoding: try JSONEncoder().encode(record),
                as: UTF8.self
            )
            #expect(!persistedText.contains(scenario.sentinel))
            #expect(!persistedText.contains("customAgentDescriptor"))
        }
    }

    @Test("Legacy custom history can adopt a descriptor but never rewrites an existing one")
    func customDescriptorMigrationIsAppendOnly() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "legacy-agent",
            name: "Legacy Agent",
            detect: CmuxVaultAgentDetectRule(processName: "legacy-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}"
        )
        let replacement = CmuxVaultAgentRegistration(
            id: "legacy-agent",
            name: "Replacement",
            detect: CmuxVaultAgentDetectRule(processName: "replacement"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "replacement --resume {{sessionId}}"
        )
        let legacy = try #require(UniConnectLocalAgentConversation(
            kind: .custom("legacy-agent"),
            sessionID: "legacy-session",
            resumeWorkingDirectory: "/repo",
            firstSeenAt: 1
        ))
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            conversations: [legacy],
            latestConversationID: legacy.id,
            createdAt: 1,
            updatedAt: 1
        )
        #expect(record.latestRestorableSnapshot(registry: emptyRegistry) == nil)
        #expect(
            record.latestRestorableSnapshot(
                registry: CmuxVaultAgentRegistry(registrations: [registration])
            )?.resumeCommand != nil
        )
        let legacyRecord = record

        let observed = SessionRestorableAgentSnapshot(
            kind: .custom("legacy-agent"),
            sessionId: "legacy-session",
            workingDirectory: "/repo",
            launchCommand: nil,
            registration: registration
        )
        let didAdoptDescriptor = record.record(observed, at: 2)
        #expect(didAdoptDescriptor)
        #expect(record.conversations.count == 1)
        #expect(record.latestConversation?.customAgentDescriptor?.registration == registration)

        var changedObservation = observed
        changedObservation.registration = replacement
        let didRewriteDescriptor = record.record(changedObservation, at: 3)
        #expect(!didRewriteDescriptor)
        #expect(record.latestConversation?.customAgentDescriptor?.registration == registration)

        var imported = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            workingDirectory: "/repo/imported",
            createdAt: 1,
            updatedAt: 4
        )
        var importedObservation = observed
        importedObservation.workingDirectory = "/repo/imported"
        _ = imported.record(importedObservation, at: 4)
        var merged = legacyRecord
        let didMergeImportedState = merged.mergeImportedStatePreservingHistory(imported, at: 5)
        #expect(didMergeImportedState)
        #expect(merged.conversations.count == 1)
        #expect(merged.latestConversation?.customAgentDescriptor?.registration == registration)
        #expect(merged.latestConversation?.resumeWorkingDirectory == "/repo/imported")
    }

    @Test("Malformed custom descriptors fail closed")
    func malformedCustomDescriptorIsRejected() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "durable-agent",
            name: "Durable Agent",
            detect: CmuxVaultAgentDetectRule(processName: "durable-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("durable-agent"),
            sessionId: "durable-session",
            workingDirectory: "/repo",
            launchCommand: nil,
            registration: registration
        )
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/repo",
            createdAt: 1,
            updatedAt: 1
        )
        _ = record.record(snapshot, at: 2)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var conversations = try #require(object["conversations"] as? [[String: Any]])
        var conversation = try #require(conversations.first)
        var descriptor = try #require(
            conversation["customAgentDescriptor"] as? [String: Any]
        )
        descriptor["version"] = 99
        conversation["customAgentDescriptor"] = descriptor
        conversations[0] = conversation
        object["conversations"] = conversations

        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: malformed)
        }
    }

    @Test("Persistent history does not copy captured argv or environment secrets")
    func historyIsSecretFree() throws {
        let secret = "do-not-persist-this-token"
        let captured = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "cursor-session-1",
            workingDirectory: "/Users/test/repository",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/cursor-agent",
                arguments: ["cursor-agent", "--api-key", secret],
                workingDirectory: "/Users/test/repository",
                environment: ["API_KEY": secret],
                capturedAt: 500,
                source: "agent-hook"
            )
        )
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 500,
            updatedAt: 500
        )
        let recordedCapture = record.record(captured, at: 501)
        #expect(recordedCapture)

        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("API_KEY"))
        #expect(!text.contains("--api-key"))
    }

    @Test("Oversized untrusted local-window fields fail closed during decode")
    func oversizedFieldsAreRejected() throws {
        var conversationObject: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "codex",
            "sessionID": String(
                repeating: "s",
                count: UniConnectLocalAgentConversation.maximumSessionIDUTF8Bytes + 1
            ),
            "displayName": "Codex",
            "firstSeenAt": 1,
        ]
        let conversationData = try JSONSerialization.data(withJSONObject: conversationObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalAgentConversation.self, from: conversationData)
        }
        conversationObject["sessionID"] = "safe-session"
        conversationObject["displayName"] = String(
            repeating: "d",
            count: UniConnectLocalAgentConversation.maximumDisplayNameUTF8Bytes + 1
        )
        let oversizedDisplayNameData = try JSONSerialization.data(withJSONObject: conversationObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                UniConnectLocalAgentConversation.self,
                from: oversizedDisplayNameData
            )
        }
        conversationObject["displayName"] = "Codex"
        conversationObject["resumeWorkingDirectory"] = "relative/repository"
        let relativeConversationCWDData = try JSONSerialization.data(withJSONObject: conversationObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                UniConnectLocalAgentConversation.self,
                from: relativeConversationCWDData
            )
        }

        var recordObject: [String: Any] = [
            "version": 1,
            "id": UUID().uuidString,
            "visibleName": String(
                repeating: "n",
                count: UniConnectLocalWindowRecord.maximumVisibleNameUTF8Bytes + 1
            ),
            "boxRoot": "/Users/test/repository",
            "runtimeState": "shell",
            "conversations": [],
            "createdAt": 1,
            "updatedAt": 1,
        ]
        let recordData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: recordData)
        }
        recordObject["visibleName"] = "Safe"
        recordObject["boxRoot"] = "/" + String(
            repeating: "r",
            count: UniConnectLocalWindowRecord.maximumBoxRootUTF8Bytes
        )
        let oversizedRootData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: oversizedRootData)
        }

        recordObject["boxRoot"] = "relative/project"
        let relativeRootData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: relativeRootData)
        }
        #expect(UniConnectLocalWindowRecord.validatedBoxRoot("relative/project") == nil)
        #expect(UniConnectLocalWindowRecord.validatedBoxRoot("~/project")?.hasPrefix("/") == true)

        recordObject["version"] = 2
        recordObject["boxRoot"] = "/repo"
        recordObject["workingDirectory"] = "/outside/repo"
        let outsideWorkingDirectoryData = try JSONSerialization.data(withJSONObject: recordObject)
        let independentRecord = try JSONDecoder().decode(
            UniConnectLocalWindowRecord.self,
            from: outsideWorkingDirectoryData
        )
        #expect(independentRecord.boxRoot == "/repo")
        #expect(independentRecord.workingDirectory == "/outside/repo")
        recordObject["workingDirectory"] = "repo/api"
        let relativeWorkingDirectoryData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: relativeWorkingDirectoryData)
        }
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory("/repo/api", within: "/repo")
                == "/repo/api"
        )
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory("/repo-other", within: "/repo")
                == "/repo-other"
        )
        #expect(UniConnectLocalWindowRecord.validatedWorkingDirectory("/tmp/bad\npath", within: "/repo") == nil)
        #expect(UniConnectLocalWindowRecord.validatedWorkingDirectory("/tmp/bad\u{0}path", within: "/repo") == nil)
    }

    @Test("A selected symlink to another local folder remains a valid independent cwd")
    func workingDirectoryAcceptsIndependentSymlink() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-cwd-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("repo", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        let escape = root.appendingPathComponent("escape", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory(
                escape.path,
                within: root.path
            ) == escape.path
        )
        let futureDirectory = escape.appendingPathComponent("not-created/deep", isDirectory: true).path
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory(
                futureDirectory,
                within: root.path
            ) == futureDirectory
        )
        #expect(UniConnectLocalBoxRootPolicy.isAvailableDirectory(escape.path))
        #expect(!UniConnectLocalBoxRootPolicy.isAvailableDirectory(futureDirectory))
    }

    @Test("Terminal snapshot round trip retains the generic local-window history")
    func terminalSnapshotRoundTripsGenericHistory() throws {
        var record = UniConnectLocalWindowRecord(
            visibleName: "Mixed agents",
            boxRoot: "/Users/test/repository",
            workingDirectory: "/Users/test/repository/api",
            tmuxBinding: UniConnectLocalTmuxBinding(name: "uc-test-history", socketName: "uniconnect-local"),
            createdAt: 600,
            updatedAt: 600
        )
        _ = record.record(agent(.claude, sessionID: "60000000-0000-0000-0000-000000000001"), at: 601)
        _ = record.transitionToShell(at: 602)
        _ = record.record(agent(.antigravity, sessionID: "agy-conversation-2"), at: 603)
        _ = record.transitionToShell(at: 604)
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: record.workingDirectory,
            agent: record.latestRestorableSnapshot(registry: emptyRegistry),
            wasAgentRunning: false,
            uniConnectClaudeSession: nil,
            uniConnectLocalWindow: record
        )

        let data = try JSONEncoder().encode(terminal)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.uniConnectLocalWindow == record)
        #expect(decoded.uniConnectLocalWindow?.conversations.count == 2)
        #expect(decoded.uniConnectLocalWindow?.latestConversation?.kind == .antigravity)
        #expect(decoded.uniConnectLocalWindow?.runtimeState == .shell)
        #expect(decoded.workingDirectory == "/Users/test/repository/api")
        #expect(decoded.agent?.workingDirectory == "/Users/test/repository/api")
        #expect(decoded.uniConnectLocalWindow?.tmuxBinding == record.tmuxBinding)
    }

    @Test("Legacy direct PTYs stay unbound when decoded and saved again")
    func legacyPTYDoesNotBecomeTmuxOnSave() throws {
        let data = Data(#"{"version":3,"boxRoot":"/repo","runtimeState":"shell","conversations":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)
        #expect(legacy.tmuxBinding == nil)
        let restored = try JSONDecoder().decode(
            UniConnectLocalWindowRecord.self, from: JSONEncoder().encode(legacy)
        )
        #expect(restored.tmuxBinding == nil)
        #expect(restored.id == legacy.id)
    }

    @Test("Merging imported history cannot redirect an existing host-local tmux binding")
    func importedHistoryDoesNotReplaceLiveTmuxIdentity() throws {
        let binding = try #require(UniConnectLocalTmuxBinding(name: "live-pane", socketName: "uniconnect-local"))
        var local = UniConnectLocalWindowRecord(boxRoot: "/repo", tmuxBinding: binding)
        var imported = UniConnectLocalWindowRecord(
            boxRoot: "/other-host",
            tmuxBinding: UniConnectLocalTmuxBinding(name: "other-pane", socketName: "foreign")
        )
        _ = imported.record(agent(.codex, sessionID: "thread-to-preserve"))
        _ = local.mergeImportedStatePreservingHistory(imported)
        #expect(local.tmuxBinding == binding)
        #expect(local.latestConversation?.sessionID == "thread-to-preserve")
    }

    private func agent(
        _ kind: RestorableAgentKind,
        sessionID: String
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: "/tmp/a-different-cwd",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: kind.rawValue,
                arguments: [kind.rawValue],
                workingDirectory: "/tmp/a-different-cwd",
                environment: nil,
                capturedAt: 1,
                source: "test"
            )
        )
    }
}
