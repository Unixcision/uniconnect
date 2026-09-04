import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect transactional import")
@MainActor
struct UniConnectImportTransactionTests {
    @Test("A real update commits durably without duplicating the workspace")
    func updateCommitsWithoutDuplication() async throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let existing = document([local(id: id, name: "Old name")])
        let imported = document([local(id: id, name: "New name")])
        let prepared = UniConnectImportPlanner().prepare(
            importing: imported,
            against: existing
        )
        let selection = UniConnectImportSelection.allMutations(in: prepared.plan)
        let adapter = FakeImportAdapter(document: existing)
        let journal = FakeImportJournal()
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 100 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: selection,
            adapter: adapter
        )

        guard case .committed(_, let rows) = result else {
            Issue.record("Expected a committed transaction, got \(result)")
            return
        }
        #expect(rows == [0])
        #expect(adapter.document.workspaces.count == 1)
        #expect(adapter.document.workspaces.first?.name == "New name")
        #expect(adapter.persistCount == 1)
        #expect(adapter.deletedCheckpointIDs.count == 1)
        #expect(await journal.currentRecord() == nil)
        #expect(await journal.savedPhases().contains(.committed))
    }

    @Test("A failure after one mutation restores and verifies the exact checkpoint")
    func mutationFailureRollsBack() async throws {
        let existing = document([local(name: "Existing")])
        let imported = document([local(name: "First"), local(name: "Second")])
        let prepared = UniConnectImportPlanner().prepare(
            importing: imported,
            against: existing
        )
        let adapter = FakeImportAdapter(document: existing, failOnRowID: 1)
        let journal = FakeImportJournal()
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 200 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .mutationFailed(rowID: 1)) = result else {
            Issue.record("Expected a verified rollback, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.rollbackCount == 1)
        #expect(adapter.verifyRollbackCount == 1)
        #expect(adapter.deletedCheckpointIDs.count == 1)
        #expect(await journal.savedPhases().contains(.rollingBack))
        #expect(await journal.savedPhases().contains(.rollbackComplete))
        #expect(await journal.currentRecord() == nil)
    }

    @Test("Missing declared-existing tmux blocks before checkpoint or mutation")
    func missingTmuxBlocksBeforeMutation() async throws {
        let markdown = """
        ## Cajas SSH
        ### Production — tmux EXISTENTE (no crear)
        ```bash
        ssh ops@example.test
        ```
        | Ventana | tmux |
        |---|---|
        | worker | worker_1 |
        """
        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let existing = document([])
        let prepared = UniConnectImportPlanner().prepare(
            importing: parsed,
            against: existing
        )
        let adapter = FakeImportAdapter(document: existing)
        let verifier = FakeTmuxVerifier(status: .unavailable)
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: verifier,
            makeID: DeterministicIDs().next,
            now: { 300 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .failedBeforeMutation(.remoteSessionsUnavailable(let windows)) = result else {
            Issue.record("Expected read-only preflight rejection, got \(result)")
            return
        }
        #expect(windows == [.init(workspaceIndex: 0, windowIndex: 0)])
        #expect(adapter.checkpointCount == 0)
        #expect(adapter.appliedRowIDs.isEmpty)
        let invocations = await verifier.receivedInvocations()
        #expect(invocations.count == 1)
        #expect(invocations[0].arguments.last == "tmux has-session -t 'worker_1'")
        #expect(!invocations[0].arguments.joined(separator: " ").contains("new-session"))
        #expect(!invocations[0].arguments.joined(separator: " ").contains("attach-session"))
    }

    @Test("Startup recovery rolls back an interrupted applying journal")
    func interruptedJournalRollsBack() async throws {
        let original = document([local(name: "Original")])
        let mutated = document([local(name: "Original"), local(name: "Partial")])
        let checkpointID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let transactionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let adapter = FakeImportAdapter(document: mutated)
        adapter.installCheckpoint(id: checkpointID, document: original)
        let journal = FakeImportJournal(record: .init(
            transactionID: transactionID,
            checkpointID: checkpointID,
            sourceDigest: "fixture-digest",
            selectedRowIDs: [0, 1],
            completedRowIDs: [0],
            nextRowID: 1,
            phase: .applying,
            createdAt: 10,
            updatedAt: 11
        ))
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 400 }
        )

        let result = await transaction.recoverInterruptedTransaction(adapter: adapter)

        guard case .rolledBack(let recoveredID, .cancelled) = result else {
            Issue.record("Expected interrupted transaction rollback, got \(String(describing: result))")
            return
        }
        #expect(recoveredID == transactionID)
        #expect(adapter.document == original)
        #expect(adapter.deletedCheckpointIDs == [checkpointID])
        #expect(adapter.pruneCutoffs.count == 1)
        #expect(await journal.currentRecord() == nil)
    }

    @Test("A rejected durable save rolls the import back before reporting success")
    func durableSaveRejectionRollsBack() async {
        let existing = document([local(name: "Existing")])
        let imported = document([local(name: "Existing"), local(name: "Imported")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing, failPersistAtCall: 1)
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 450 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .persistenceFailed) = result else {
            Issue.record("Expected the rejected durable save to roll back, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.persistCount == 2)
        #expect(adapter.deletedCheckpointIDs.count == 1)
    }

    @Test("A failed rollback retains its encrypted checkpoint and journal")
    func rollbackFailureRetainsCheckpoint() async {
        let existing = document([local(name: "Existing")])
        let imported = document([local(name: "First"), local(name: "Second")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing, failOnRowID: 1)
        adapter.rollbackVerificationSucceeds = false
        let journal = FakeImportJournal()
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 475 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rollbackFailed(_, .mutationFailed(rowID: 1)) = result else {
            Issue.record("Expected rollback failure, got \(result)")
            return
        }
        #expect(adapter.deletedCheckpointIDs.isEmpty)
        #expect(adapter.remainingCheckpointCount == 1)
        #expect(await journal.currentRecord()?.phase == .rollingBack)
    }

    @Test("Startup retries terminal checkpoint cleanup and prunes stale orphans")
    func startupCleansTerminalCheckpointAndPrunes() async {
        let checkpointID = UUID(uuidString: "CCCCCCCC-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
        let transactionID = UUID(uuidString: "DDDDDDDD-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
        let original = document([local(name: "Committed")])
        let adapter = FakeImportAdapter(document: original)
        adapter.installCheckpoint(id: checkpointID, document: original)
        let journal = FakeImportJournal(record: .init(
            transactionID: transactionID,
            checkpointID: checkpointID,
            sourceDigest: "fixture-digest",
            selectedRowIDs: [0],
            completedRowIDs: [0],
            nextRowID: nil,
            phase: .committed,
            createdAt: 10,
            updatedAt: 11
        ))
        let now: TimeInterval = 10 * 24 * 60 * 60
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { now }
        )

        let result = await transaction.recoverInterruptedTransaction(adapter: adapter)

        #expect(result == .some(.noChanges))
        #expect(adapter.deletedCheckpointIDs == [checkpointID])
        #expect(adapter.remainingCheckpointCount == 0)
        #expect(adapter.pruneCutoffs == [Date(timeIntervalSince1970: 3 * 24 * 60 * 60)])
        #expect(await journal.currentRecord() == nil)
    }

    @Test("Checkpoint cleanup failure keeps the committed journal for a startup retry")
    func committedCleanupFailureRetriesAtStartup() async {
        let existing = document([])
        let imported = document([local(name: "Committed")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        adapter.failCheckpointDeletion = true
        let journal = FakeImportJournal()
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 11 * 24 * 60 * 60 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .committed = result else {
            Issue.record("Expected committed import despite deferred cleanup, got \(result)")
            return
        }
        #expect(adapter.remainingCheckpointCount == 1)
        #expect(await journal.currentRecord()?.phase == .committed)

        let blockedRecovery = await transaction.recoverInterruptedTransaction(adapter: adapter)
        #expect(blockedRecovery == .some(.failedBeforeMutation(.checkpointFailed)))
        #expect(adapter.remainingCheckpointCount == 1)
        #expect(adapter.pruneCutoffs.isEmpty)
        #expect(await journal.currentRecord()?.phase == .committed)

        adapter.failCheckpointDeletion = false
        let recoveryResult = await transaction.recoverInterruptedTransaction(adapter: adapter)

        #expect(recoveryResult == .some(.noChanges))
        #expect(adapter.remainingCheckpointCount == 0)
        #expect(adapter.deletedCheckpointIDs.count == 1)
        #expect(await journal.currentRecord() == nil)
    }

    @Test("Safe selected rows commit even when another source declaration is rejected")
    func selectionSkipsRejectedRows() async throws {
        let existing = document([])
        let imported = document([
            local(name: "Safe"),
            .init(
                name: "",
                kind: .local,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: "/Users/test/Projects/Rejected",
                connect: nil,
                windows: []
            ),
        ])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 500 }
        )

        #expect(prepared.plan.rows.map(\.outcome) == [.create, .rejected])
        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .committed(_, let rowIDs) = result else {
            Issue.record("Expected the selected safe row to commit, got \(result)")
            return
        }
        #expect(rowIDs == [0])
        #expect(adapter.document.workspaces.map(\.name) == ["Safe"])
    }

    @Test("Duplicate Claude fallback survives live-state revalidation and commits as a shell")
    func duplicateClaudeFallbackCommits() async throws {
        let session = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let imported = document([
            .init(
                name: "Apps",
                kind: .local,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: "/Users/test/Projects/Apps",
                connect: nil,
                windows: [
                    .init(
                        name: "APP 1",
                        tmux: nil,
                        claudeSession: session,
                        cwd: "/Users/test/Projects/Apps",
                        isPinned: nil
                    ),
                    .init(
                        name: "APP 4",
                        tmux: nil,
                        claudeSession: session,
                        cwd: "/Users/test/Projects/Apps",
                        isPinned: nil
                    ),
                ]
            ),
        ])
        let existing = document([])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 600 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .committed = result else {
            Issue.record("Expected duplicate fallback import to commit, got \(result)")
            return
        }
        let windows = try #require(adapter.document.workspaces.first?.windows)
        #expect(windows.count == 2)
        #expect(windows[0].claudeSession == session)
        #expect(windows[1].claudeSession == nil)
    }

    @Test("Journal digest is independent of an embedded SSH password")
    func digestDoesNotFingerprintPassword() {
        func remote(password: String) -> UniConnectDocument {
            document([
                .init(
                    name: "Remote",
                    kind: .ssh,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: nil,
                    connect: "sshpass -p '\(password)' ssh ops@example.test",
                    windows: [
                        .init(
                            name: "worker",
                            tmux: "worker_1",
                            claudeSession: nil,
                            cwd: nil,
                            isPinned: nil
                        ),
                    ]
                ),
            ])
        }
        let existing = document([])
        let first = UniConnectImportPlanner().prepare(
            importing: remote(password: "first-fixture-secret"),
            against: existing
        )
        let second = UniConnectImportPlanner().prepare(
            importing: remote(password: "second-fixture-secret"),
            against: existing
        )

        #expect(first.sourceDigest == second.sourceDigest)
        #expect(!first.sourceDigest.contains("fixture-secret"))
    }

    @Test("Failure to durably mark committed rolls the already-persisted mutation back")
    func committedJournalFailureRollsBack() async {
        let existing = document([])
        let imported = document([local(name: "Would otherwise commit")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        let journal = FakeImportJournal(failSavingPhase: .committed)
        let transaction = UniConnectImportTransaction(
            journal: journal,
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 700 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .journalFailed) = result else {
            Issue.record("Expected a verified rollback, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.persistCount == 2)
        #expect(adapter.verifyRollbackCount == 1)
    }

    @Test("Persistence and import checkpoints share the same starter-free workspace boundary")
    func backupExcludesStarterAcrossMultipleWindowManagers() throws {
        let starterManager = TabManager()
        let contentManager = TabManager()
        let starter = try #require(starterManager.tabs.first)
        let content = try #require(contentManager.tabs.first)
        starter.uniConnectIsStarter = true
        starter.uniConnectProfile = nil
        content.uniConnectIsStarter = false
        content.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
            localRoot: content.currentDirectory
        )
        content.setCustomTitle("Durable workspace")

        let persisted = UniConnectBackup.buildDocument(
            tabManagers: [starterManager, contentManager]
        )

        #expect(persisted.workspaces.count == 1)
        #expect(persisted.workspaces.first?.name == "Durable workspace")
        #expect(persisted.workspaces.first?.id == content.uniConnectProfile?.importIdentity)
    }

    @Test("SSH reconciliation removes only unbound terminals once a tmux window exists")
    func sshReconciliationRemovesInheritedLocalTerminal() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let inheritedLocalPanelID = try #require(workspace.panels.first(where: {
            $0.value is TerminalPanel
        })?.key)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let boundPanelID = try #require(
            workspace.newTerminalSurface(inPane: pane, focus: false)?.id
        )
        workspace.uniConnectProfile = .init(
            kind: .ssh,
            credentialId: UUID(uuidString: "54545454-5454-5454-5454-545454545454"),
            hostLabel: "ops@example.test",
            tmuxReady: true
        )
        workspace.uniConnectTmuxSessionsByPanelId[boundPanelID] = "worker_1"

        #expect(Workspace.uniConnectStaleUnboundTerminalPanelIDs(
            isSSH: true,
            terminalPanelIDs: [inheritedLocalPanelID, boundPanelID],
            tmuxSessionsByPanelID: [boundPanelID: "worker_1"]
        ) == Set([inheritedLocalPanelID]))
        #expect(workspace.uniConnectRemoveStaleUnboundSSHTerminals())
        #expect(workspace.panels[inheritedLocalPanelID] == nil)
        #expect(workspace.panels[boundPanelID] is TerminalPanel)
        #expect(workspace.uniConnectTmuxSessionsByPanelId[boundPanelID] == "worker_1")

        #expect(Workspace.uniConnectStaleUnboundTerminalPanelIDs(
            isSSH: true,
            terminalPanelIDs: [inheritedLocalPanelID],
            tmuxSessionsByPanelID: [:]
        ).isEmpty)
        #expect(Workspace.uniConnectStaleUnboundTerminalPanelIDs(
            isSSH: false,
            terminalPanelIDs: [inheritedLocalPanelID, boundPanelID],
            tmuxSessionsByPanelID: [boundPanelID: "worker_1"]
        ).isEmpty)
    }

    @Test("Changing an SSH endpoint rechecks and rebuilds the same tmux window, then rollback returns to the old endpoint")
    func endpointChangeSameTmuxRollsBackToOriginalEndpoint() async throws {
        let id = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let oldConnect = "ssh ops@old.example.test"
        let newConnect = "ssh ops@new.example.test"
        let existing = document([remote(id: id, connect: oldConnect)])
        let imported = document([remote(id: id, connect: newConnect)])
        let prepared = UniConnectImportPlanner().prepare(
            importing: imported,
            against: existing
        )
        let window = try #require(prepared.plan.rows.first?.windowRows.first)
        guard case .update(.attachExistingTmux(session: "worker_1")) = window.action else {
            Issue.record("An endpoint change must rebuild the existing tmux attachment")
            return
        }
        let adapter = FakeImportAdapter(
            document: existing,
            failPersistAtCall: 1
        )
        let verifier = FakeTmuxVerifier(status: .available)
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: verifier,
            makeID: DeterministicIDs().next,
            now: { 800 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .persistenceFailed) = result else {
            Issue.record("Expected endpoint update rollback, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.activeSSHConnect == oldConnect)
        #expect(adapter.appliedSSHConnects == [newConnect])
        let invocation = try #require(await verifier.receivedInvocations().first)
        #expect(invocation.arguments.contains("ops@new.example.test"))
        #expect(invocation.arguments.last == "tmux has-session -t 'worker_1'")
        #expect(!invocation.arguments.joined(separator: " ").contains("new-session"))
    }

    @Test("A declared remote session disappearing after preflight aborts and rolls back")
    func remoteDisappearsAfterPreflightRollsBack() async {
        let id = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let existing = document([])
        let imported = document([remote(id: id, connect: "ssh ops@example.test")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        adapter.verificationSucceeds = false
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 900 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .mutationFailed(rowID: 0)) = result else {
            Issue.record("Expected the dead attach child to roll back, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.rollbackCount == 1)
        #expect(adapter.persistCount == 1)
    }

    @Test("A concurrent mutation is retained while the import delta is rolled back")
    func concurrentMutationUsesConditionalRollback() async {
        let existing = document([local(name: "Existing")])
        let imported = document([local(name: "Existing"), local(name: "Imported")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let adapter = FakeImportAdapter(document: existing)
        adapter.injectConcurrentMutationDuringVerification = true
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 1_000 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .rolledBack(_, .stateChanged) = result else {
            Issue.record("Expected a conditional state-change rollback, got \(result)")
            return
        }
        #expect(adapter.document == existing)
        #expect(adapter.externalRevision == 1)
    }

    @Test("Checkpoint captures the model and encrypted vault before repository handoff")
    func checkpointCapturesCoherentStateBundle() async throws {
        let checkpoints = CapturingImportCheckpointRepository()
        let document = document([local(name: "Before import")])
        let snapshot = sessionSnapshotFixture()
        let encryptedVault = Data("captured-vault-revision".utf8)
        var capturePhase = 0
        let adapter = UniConnectLiveImportAdapter(
            checkpoints: checkpoints,
            readDocument: {
                #expect(capturePhase == 0)
                capturePhase = 1
                return document
            },
            readCheckpointSnapshot: {
                #expect(capturePhase == 1)
                capturePhase = 2
                return snapshot
            },
            readStateSnapshot: { snapshot },
            applyMutation: { _ in },
            verifyMutation: { _ in true },
            finalizeMutation: { _ in },
            persist: {},
            restoreSessionSnapshot: { _ in },
            readVaultSnapshot: {
                #expect(capturePhase == 2)
                capturePhase = 3
                return encryptedVault
            },
            restoreVault: { _ in },
            restoreVaultDelta: { checkpoint, _ in checkpoint },
            verifyVault: { _ in true }
        )
        let checkpointID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!

        try await adapter.createCheckpoint(id: checkpointID)

        #expect(capturePhase == 3)
        #expect(await checkpoints.capturedID() == checkpointID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedDocumentData = try encoder.encode(document)
        let expectedSnapshotData = try encoder.encode(snapshot)
        #expect(await checkpoints.capturedDocumentData() == expectedDocumentData)
        #expect(await checkpoints.capturedSnapshotData() == expectedSnapshotData)
        #expect(await checkpoints.capturedVault() == encryptedVault)
    }

    @Test("SSH PTY telemetry changing during attach does not roll back a valid import")
    func volatileSSHTelemetryDuringVerificationCommits() async throws {
        let workspaceID = UUID(uuidString: "51515151-5151-5151-5151-515151515151")!
        let existing = document([])
        let imported = document([remote(id: workspaceID, connect: "ssh ops@example.test")])
        let prepared = UniConnectImportPlanner().prepare(importing: imported, against: existing)
        let checkpoints = CapturingImportCheckpointRepository()
        var liveDocument = existing
        var liveSnapshot = sessionSnapshotFixture()
        var importedSnapshot = liveSnapshot
        importedSnapshot.windows[0].tabManager.workspaces[0].customTitle = "Remote fixture"
        importedSnapshot.windows[0].tabManager.workspaces[0].uniConnect = .init(
            kind: .ssh,
            importIdentity: workspaceID,
            credentialId: UUID(uuidString: "52525252-5252-5252-5252-525252525252"),
            hostLabel: "ops@example.test",
            tmuxReady: false,
            localRoot: nil,
            createdAt: 10,
            lastActivityAt: 10
        )
        importedSnapshot.windows[0].tabManager.workspaces[0]
            .panels[0].terminal?.uniConnectTmuxSession = "worker_1"
        let encryptedVault = Data("immutable-vault-fixture".utf8)
        let adapter = UniConnectLiveImportAdapter(
            checkpoints: checkpoints,
            readDocument: { liveDocument },
            readCheckpointSnapshot: { liveSnapshot },
            readStateSnapshot: { liveSnapshot },
            applyMutation: { mutation in
                liveDocument = try UniConnectDocumentReconciler().applying(
                    mutation,
                    to: liveDocument
                )
                liveSnapshot = importedSnapshot
            },
            verifyMutation: { _ in
                liveSnapshot.windows[0].tabManager.workspaces[0].processTitle = "ssh"
                liveSnapshot.windows[0].tabManager.workspaces[0].currentDirectory = "/remote/work"
                liveSnapshot.windows[0].tabManager.workspaces[0].panels[0].title = "remote prompt"
                liveSnapshot.windows[0].tabManager.workspaces[0].panels[0].directory = "/remote/work"
                liveSnapshot.windows[0].tabManager.workspaces[0].panels[0].ttyName = "ttys099"
                liveSnapshot.windows[0].tabManager.workspaces[0]
                    .panels[0].terminal?.workingDirectory = "/remote/work"
                liveSnapshot.windows[0].tabManager.workspaces[0]
                    .panels[0].terminal?.wasAgentRunning = true
                return true
            },
            finalizeMutation: { _ in },
            persist: {},
            restoreSessionSnapshot: { liveSnapshot = $0 },
            readVaultSnapshot: { encryptedVault },
            restoreVault: { _ in },
            restoreVaultDelta: { checkpoint, _ in checkpoint },
            verifyVault: { _ in true }
        )
        let transaction = UniConnectImportTransaction(
            journal: FakeImportJournal(),
            tmuxVerifier: FakeTmuxVerifier(status: .available),
            makeID: DeterministicIDs().next,
            now: { 1_050 }
        )

        let result = await transaction.execute(
            prepared: prepared,
            selection: .allMutations(in: prepared.plan),
            adapter: adapter
        )

        guard case .committed = result else {
            Issue.record("Expected volatile SSH telemetry to be ignored, got \(result)")
            return
        }
        #expect(liveDocument == imported)
    }

    @Test("SSH import token still detects structural and canonical binding changes")
    func sshStateTokenDetectsCanonicalChanges() throws {
        var baseline = sessionSnapshotFixture()
        baseline.windows[0].tabManager.workspaces[0].uniConnect = .init(
            kind: .ssh,
            credentialId: UUID(uuidString: "53535353-5353-5353-5353-535353535353"),
            hostLabel: "ops@example.test",
            tmuxReady: true
        )
        baseline.windows[0].tabManager.workspaces[0]
            .panels[0].terminal?.uniConnectTmuxSession = "worker_1"
        let vault = Data("vault-revision".utf8)
        let baselineToken = try UniConnectLiveImportAdapter.stateToken(
            snapshot: baseline,
            encryptedVault: vault
        )

        var volatile = baseline
        volatile.windows[0].tabManager.workspaces[0].uniConnect?.lastActivityAt = 999
        volatile.windows[0].tabManager.workspaces[0].processTitle = "changed prompt"
        volatile.windows[0].tabManager.workspaces[0].panels[0].title = "changed title"
        volatile.windows[0].tabManager.workspaces[0].panels[0].customTitle =
            "Shell · disconnected"
        volatile.windows[0].tabManager.workspaces[0].panels[0].ttyName = "ttys088"
        volatile.windows[0].tabManager.workspaces[0]
            .panels[0].terminal?.wasAgentRunning = true
        #expect(try UniConnectLiveImportAdapter.stateToken(
            snapshot: volatile,
            encryptedVault: vault
        ) == baselineToken)

        var renamed = baseline
        renamed.windows[0].tabManager.workspaces[0].customTitle = "Concurrent rename"
        #expect(try UniConnectLiveImportAdapter.stateToken(
            snapshot: renamed,
            encryptedVault: vault
        ) != baselineToken)

        var rebound = baseline
        rebound.windows[0].tabManager.workspaces[0]
            .panels[0].terminal?.uniConnectTmuxSession = "other_worker"
        #expect(try UniConnectLiveImportAdapter.stateToken(
            snapshot: rebound,
            encryptedVault: vault
        ) != baselineToken)
    }

    @Test("Snapshot rollback preserves browser, split, stable IDs, and selection exactly")
    func snapshotRollbackIsExactForFullPanelGraph() throws {
        let checkpoint = sessionSnapshotFixture()
        var imported = checkpoint
        imported.windows[0].tabManager.workspaces[0].customTitle = "Imported title"

        let restored = try UniConnectImportSnapshotMerger.reverting(
            imported: imported,
            to: checkpoint,
            preserving: imported
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(restored) == encoder.encode(checkpoint))
    }

    @Test("Three-way snapshot rollback preserves an external browser and selection edit")
    func snapshotRollbackPreservesConcurrentPanelMutation() throws {
        let checkpoint = sessionSnapshotFixture()
        let browserID = checkpoint.windows[0].tabManager.workspaces[0].panels[1].id
        var imported = checkpoint
        imported.windows[0].tabManager.workspaces[0].customTitle = "Imported title"
        var current = imported
        current.windows[0].tabManager.workspaces[0].focusedPanelId = browserID
        current.windows[0].tabManager.workspaces[0].panels[1].browser?.urlString =
            "https://docs.example.test/concurrent"
        if case .split(var split) = current.windows[0].tabManager.workspaces[0].layout {
            split.dividerPosition = 0.72
            split.second = .pane(.init(panelIds: [browserID], selectedPanelId: browserID))
            current.windows[0].tabManager.workspaces[0].layout = .split(split)
        }

        let restored = try UniConnectImportSnapshotMerger.reverting(
            imported: imported,
            to: checkpoint,
            preserving: current
        )
        let workspace = restored.windows[0].tabManager.workspaces[0]
        #expect(workspace.customTitle == "Before import")
        #expect(workspace.workspaceId == checkpoint.windows[0].tabManager.workspaces[0].workspaceId)
        #expect(workspace.focusedPanelId == browserID)
        #expect(workspace.panels.map(\.id) == checkpoint.windows[0].tabManager.workspaces[0].panels.map(\.id))
        #expect(workspace.panels[1].browser?.urlString == "https://docs.example.test/concurrent")
        guard case .split(let split) = workspace.layout else {
            Issue.record("Expected split layout to survive")
            return
        }
        #expect(split.dividerPosition == 0.72)
    }

    @Test("Import lease gates model, menu, shortcut, and socket mutation entrypoints")
    func importLeaseGatesSharedEntryPoints() async throws {
        let gate = UniConnectImportMutationGate()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-import-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        UniConnectCoordinator.shared.configureImportRuntime(
            transaction: UniConnectImportTransaction(
                journal: FakeImportJournal(),
                tmuxVerifier: FakeTmuxVerifier(status: .available)
            ),
            checkpoints: UniConnectImportCheckpointRepository(
                directory: temporary.appendingPathComponent("checkpoints", isDirectory: true)
            ),
            mutationGate: gate
        )
        let manager = TabManager(importMutationGate: gate)
        let originalWorkspaceCount = manager.tabs.count
        let originalWorkspace = try #require(manager.selectedWorkspace)
        let originalPanelCount = originalWorkspace.panels.count
        let pane = try #require(originalWorkspace.bonsplitController.allPaneIds.first)
        let lease = try gate.acquire()
        defer { _ = gate.release(lease) }

        #expect(!gate.allowsMutation)
        _ = manager.addWorkspace(title: "Must not be created")
        #expect(manager.tabs.count == originalWorkspaceCount)
        #expect(originalWorkspace.newTerminalSurface(inPane: pane) == nil)
        #expect(originalWorkspace.panels.count == originalPanelCount)
        #expect(!AppDelegate().validateMenuItem(NSMenuItem(title: "Blocked", action: nil, keyEquivalent: "")))
        #expect(TerminalController.shared.handleSocketLine("close_surface deadbeef").contains("import"))

        #expect(UniConnectImportMutationGate.shouldConsumeShortcut(
            allowsMutation: gate.allowsMutation
        ))

        let authorizedWorkspace = await gate.withLease(lease) {
            manager.addWorkspace(title: "Authorized import workspace")
        }
        #expect(authorizedWorkspace != nil)
        #expect(manager.tabs.count == originalWorkspaceCount + 1)
    }

    private func document(_ workspaces: [UniConnectDocument.Workspace]) -> UniConnectDocument {
        UniConnectDocument(workspaces: workspaces, savedAt: Date(timeIntervalSince1970: 0))
    }

    private func local(id: UUID? = nil, name: String) -> UniConnectDocument.Workspace {
        .init(
            id: id,
            name: name,
            kind: .local,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: "/Users/test/Projects/Fixture",
            connect: nil,
            windows: [
                .init(
                    name: "shell",
                    tmux: nil,
                    claudeSession: nil,
                    cwd: "/Users/test/Projects/Fixture",
                    isPinned: nil
                ),
            ]
        )
    }

    private func remote(id: UUID, connect: String) -> UniConnectDocument.Workspace {
        .init(
            id: id,
            name: "Remote fixture",
            kind: .ssh,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: nil,
            connect: connect,
            windows: [
                .init(
                    name: "worker",
                    tmux: "worker_1",
                    claudeSession: nil,
                    cwd: nil,
                    isPinned: nil
                ),
            ]
        )
    }

    private func sessionSnapshotFixture() -> AppSessionSnapshot {
        let windowID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let workspaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let terminalID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let browserID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let terminal = SessionPanelSnapshot(
            id: terminalID,
            type: .terminal,
            title: "Terminal",
            customTitle: "Shell",
            directory: "/Users/test/Projects/Fixture",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/Users/test/Projects/Fixture"),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let browser = SessionPanelSnapshot(
            id: browserID,
            type: .browser,
            title: "Browser",
            customTitle: nil,
            directory: nil,
            isPinned: true,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "https://example.test/before",
                profileID: nil,
                shouldRenderWebView: true,
                pageZoom: 1,
                developerToolsVisible: false,
                backHistoryURLStrings: ["https://example.test/start"],
                forwardHistoryURLStrings: nil
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let layout = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .horizontal,
            dividerPosition: 0.5,
            first: .pane(.init(panelIds: [terminalID], selectedPanelId: terminalID)),
            second: .pane(.init(panelIds: [browserID], selectedPanelId: browserID))
        ))
        let workspace = SessionWorkspaceSnapshot(
            workspaceId: workspaceID,
            processTitle: "Fixture",
            customTitle: "Before import",
            customDescription: nil,
            customColor: "#123456",
            isPinned: false,
            currentDirectory: "/Users/test/Projects/Fixture",
            focusedPanelId: terminalID,
            layout: layout,
            panels: [terminal, browser],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil,
            uniConnect: .local
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 123,
            windows: [
                SessionWindowSnapshot(
                    windowId: windowID,
                    frame: nil,
                    display: nil,
                    tabManager: .init(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: .init(isVisible: true, selection: .tabs, width: 248)
                ),
            ]
        )
    }
}

private actor CapturingImportCheckpointRepository: UniConnectImportCheckpointing {
    enum FixtureError: Error { case missingCheckpoint }

    private var checkpoint: UniConnectImportCheckpoint?

    func create(
        id: UUID,
        document: UniConnectDocument,
        sessionSnapshot: AppSessionSnapshot,
        encryptedVault: Data?
    ) async throws {
        checkpoint = UniConnectImportCheckpoint(
            id: id,
            document: document,
            sessionSnapshot: sessionSnapshot,
            encryptedVault: encryptedVault
        )
    }

    func load(id: UUID) async throws -> UniConnectImportCheckpoint {
        guard let checkpoint, checkpoint.id == id else { throw FixtureError.missingCheckpoint }
        return checkpoint
    }

    func delete(id: UUID) async throws {
        if checkpoint?.id == id { checkpoint = nil }
    }

    func prune(olderThan cutoff: Date) async {
        _ = cutoff
    }

    func capturedID() -> UUID? { checkpoint?.id }
    func capturedDocumentData() -> Data? {
        guard let document = checkpoint?.document else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(document)
    }

    func capturedSnapshotData() -> Data? {
        guard let snapshot = checkpoint?.sessionSnapshot else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    func capturedVault() -> Data? { checkpoint?.encryptedVault }
}

@MainActor
private final class FakeImportAdapter: UniConnectImportTransactionApplying {
    enum FixtureError: Error { case requestedFailure }

    var document: UniConnectDocument
    var persistCount = 0
    var rollbackCount = 0
    var verifyRollbackCount = 0
    var checkpointCount = 0
    var deletedCheckpointIDs: [UUID] = []
    var pruneCutoffs: [Date] = []
    var appliedRowIDs: [Int] = []
    var appliedSSHConnects: [String] = []
    var activeSSHConnect: String?
    var failOnRowID: Int?
    var failPersistAtCall: Int?
    var failCheckpointDeletion = false
    var verificationSucceeds = true
    var rollbackVerificationSucceeds = true
    var injectConcurrentMutationDuringVerification = false
    private(set) var externalRevision = 0
    private var checkpoints: [UUID: UniConnectDocument] = [:]

    var remainingCheckpointCount: Int { checkpoints.count }

    init(
        document: UniConnectDocument,
        failOnRowID: Int? = nil,
        failPersistAtCall: Int? = nil
    ) {
        self.document = document
        self.failOnRowID = failOnRowID
        self.failPersistAtCall = failPersistAtCall
        self.activeSSHConnect = document.workspaces.first(where: { $0.kind == .ssh })?.connect
    }

    func currentDocument() async throws -> UniConnectDocument { document }

    func currentStateToken() async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document).base64EncodedString() + ":\(externalRevision)"
    }

    func createCheckpoint(id: UUID) async throws {
        checkpointCount += 1
        checkpoints[id] = document
    }

    func deleteCheckpoint(id: UUID) async throws {
        if failCheckpointDeletion { throw FixtureError.requestedFailure }
        checkpoints.removeValue(forKey: id)
        deletedCheckpointIDs.append(id)
    }

    func pruneCheckpoints(olderThan cutoff: Date) async {
        pruneCutoffs.append(cutoff)
    }

    func apply(_ mutation: UniConnectImportMutation) async throws {
        if mutation.rowID == failOnRowID { throw FixtureError.requestedFailure }
        document = try UniConnectDocumentReconciler().applying(mutation, to: document)
        appliedRowIDs.append(mutation.rowID)
        if mutation.workspace.kind == .ssh {
            activeSSHConnect = mutation.workspace.connect
            if let connect = mutation.workspace.connect {
                appliedSSHConnects.append(connect)
            }
        }
    }

    func verifyApplied(_ mutation: UniConnectImportMutation) async throws -> Bool {
        _ = mutation
        if injectConcurrentMutationDuringVerification {
            injectConcurrentMutationDuringVerification = false
            externalRevision += 1
        }
        return verificationSucceeds
    }

    func finalizeVerified(_ mutation: UniConnectImportMutation) async throws {
        _ = mutation
    }

    func persistDurably() async throws {
        persistCount += 1
        if persistCount == failPersistAtCall { throw FixtureError.requestedFailure }
    }

    func verifyCommitted(_ mutations: [UniConnectImportMutation]) async throws -> Bool {
        let replanned = UniConnectImportPlanner().plan(
            importing: UniConnectDocument(
                workspaces: mutations.map(\.workspace),
                savedAt: Date(timeIntervalSince1970: 0)
            ),
            against: document
        )
        return replanned.rows.allSatisfy { $0.outcome == .unchanged }
    }

    func rollback(to checkpointID: UUID, expectedStateToken: String?) async throws {
        _ = expectedStateToken
        guard let checkpoint = checkpoints[checkpointID] else { throw FixtureError.requestedFailure }
        rollbackCount += 1
        document = checkpoint
        activeSSHConnect = checkpoint.workspaces.first(where: { $0.kind == .ssh })?.connect
    }

    func verifyRolledBack(to checkpointID: UUID) async throws -> Bool {
        verifyRollbackCount += 1
        return rollbackVerificationSucceeds && checkpoints[checkpointID] == document
    }

    func installCheckpoint(id: UUID, document: UniConnectDocument) {
        checkpoints[id] = document
    }
}

private actor FakeImportJournal: UniConnectImportJournalWriting {
    enum FixtureError: Error { case requestedFailure }

    private var record: UniConnectImportJournalRecord?
    private var phases: [UniConnectImportJournalRecord.Phase] = []
    private let failSavingPhase: UniConnectImportJournalRecord.Phase?

    init(
        record: UniConnectImportJournalRecord? = nil,
        failSavingPhase: UniConnectImportJournalRecord.Phase? = nil
    ) {
        self.record = record
        self.failSavingPhase = failSavingPhase
    }

    func load() async throws -> UniConnectImportJournalRecord? { record }

    func save(_ record: UniConnectImportJournalRecord) async throws {
        if record.phase == failSavingPhase { throw FixtureError.requestedFailure }
        self.record = record
        phases.append(record.phase)
    }

    func clear(transactionID: UUID) async throws {
        if record?.transactionID == transactionID { record = nil }
    }

    func currentRecord() -> UniConnectImportJournalRecord? { record }
    func savedPhases() -> [UniConnectImportJournalRecord.Phase] { phases }
}

private actor FakeTmuxVerifier: UniConnectExistingTmuxVerifying {
    private let status: UniConnectExistingTmuxVerification.Status
    private var invocations: [UniConnectSSHProcessInvocation] = []

    init(status: UniConnectExistingTmuxVerification.Status) {
        self.status = status
    }

    func verify(
        _ requirements: [UniConnectExistingTmuxRequirement]
    ) async -> [UniConnectExistingTmuxVerification] {
        invocations.append(contentsOf: requirements.map(\.invocation))
        return requirements.map {
            .init(
                workspaceRowID: $0.workspaceRowID,
                windowID: $0.windowID,
                session: $0.session,
                status: status
            )
        }
    }

    func receivedInvocations() -> [UniConnectSSHProcessInvocation] { invocations }
}

private final class DeterministicIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 1

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let suffix = String(format: "%012llX", counter)
        counter += 1
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
