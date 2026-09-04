import Foundation
import Testing
@testable import UniConnectClaudeUpdate

@Suite("Claude update orchestration")
struct ClaudeUpdateOrchestratorTests {
    @Test func emitsTheRequiredStateSequenceAndUpdatesOncePerHost() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let first = fixture.target(id: "first")
        let second = fixture.target(id: "second")
        let harness = TestUpdaterHarness(
            targets: [first, second],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .allOpen)
        let summary = await operation.result()
        var firstPhases: [ClaudeUpdatePhase] = []
        for await snapshot in operation.progress {
            guard let phase = snapshot.targetPhases[first.id] else { continue }
            if firstPhases.last != phase { firstPhases.append(phase) }
        }
        let updateCount = await harness.updateCallCount()
        let pendingRecordCount = await harness.pendingRecordCount()
        let events = await harness.recordedEvents()
        let firstJournalIndex = events.firstIndex(of: "journal:exitRequested:\(first.id.rawValue)")
        let firstExitIndex = events.firstIndex(of: "exit:\(first.id.rawValue)")

        #expect(firstPhases == [
            .pending,
            .preflight,
            .waitingForIdle,
            .requestingExit,
            .waitingForShell,
            .updating,
            .verifyingUpdate,
            .restoring,
            .verifyingSession,
            .completed,
        ])
        #expect(summary.outcomes.count == 2)
        #expect(summary.outcomes.allSatisfy { $0.status == .updated })
        #expect(summary.hostOutcomes.map(\.status) == [.updated])
        #expect(updateCount == 1)
        #expect(pendingRecordCount == 0)
        #expect(firstJournalIndex != nil)
        #expect(firstExitIndex != nil)
        if let firstJournalIndex, let firstExitIndex {
            #expect(firstJournalIndex < firstExitIndex)
        }
    }

    @Test func updateFailureStillRestoresAndVerifiesEveryExitedSession() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "failure")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionBefore,
            updateShouldFail: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .selected(target.id))
        let summary = await operation.result()
        let outcome = try #require(summary.outcomes.first)
        let events = await harness.recordedEvents()
        let pendingRecordCount = await harness.pendingRecordCount()
        let persistedFallbackVersion = await harness.savedRecords().contains {
            $0.target.id == target.id
                && $0.stage == .shellReady
                && $0.versionAfter == fixture.versionBefore
        }

        #expect(outcome.status == .restored)
        #expect(outcome.issue == .updateCommandFailed)
        #expect(events.contains(where: { $0.hasPrefix("update:") }))
        #expect(events.contains("restore:\(target.id.rawValue)"))
        #expect(persistedFallbackVersion)
        #expect(pendingRecordCount == 0)
    }

    @Test func cancellationAfterExitSkipsUpdateButCompletesRecovery() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "cancel")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            pauseAtShell: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .selected(target.id))
        var iterator = operation.progress.makeAsyncIterator()
        while let snapshot = await iterator.next() {
            if snapshot.targetPhases[target.id] == .waitingForShell { break }
        }

        operation.cancel()
        await harness.releaseShell()
        let summary = await operation.result()
        let outcome = try #require(summary.outcomes.first)
        let events = await harness.recordedEvents()
        let updateCount = await harness.updateCallCount()
        let pendingRecordCount = await harness.pendingRecordCount()

        #expect(summary.wasCancelled)
        #expect(outcome.status == .restored)
        #expect(outcome.issue == .cancelled)
        #expect(updateCount == 0)
        #expect(events.contains("restore:\(target.id.rawValue)"))
        #expect(pendingRecordCount == 0)
    }

    @Test func cancellationAfterJournalSaveDoesNotSendExitAndRemovesTheRecord() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "cancel-before-exit")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            pauseAtExitRequestedJournalSave: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .selected(target.id))
        await harness.waitUntilExitRequestedJournalSave()
        operation.cancel()
        await harness.releaseExitRequestedJournalSave()
        let summary = await operation.result()
        let events = await harness.recordedEvents()

        #expect(summary.wasCancelled)
        #expect(!events.contains("exit:\(target.id.rawValue)"))
        #expect(!events.contains("restore:\(target.id.rawValue)"))
        #expect(await harness.updateCallCount() == 0)
        #expect(await harness.pendingRecordCount() == 0)
    }

    @Test func exactRestorationVerificationFailureKeepsRecoveryJournal() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "mismatch")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            verificationShouldMismatch: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .selected(target.id))
        let summary = await operation.result()
        let outcome = try #require(summary.outcomes.first)
        let pendingRecordCount = await harness.pendingRecordCount()

        #expect(outcome.status == .failed)
        #expect(outcome.issue == .restorationVerificationFailed)
        #expect(pendingRecordCount == 1)
    }

    @Test func restorationReceivesAndCanNeverVerifyTheOldProcessID() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "old-pid")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            verificationShouldKeepOldProcessID: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .selected(target.id))
        let summary = await operation.result()
        let outcome = try #require(summary.outcomes.first)

        #expect(await harness.replacingProcessID(for: target.id) == 42)
        #expect(outcome.status == .failed)
        #expect(outcome.issue == .restorationVerificationFailed)
        #expect(await harness.pendingRecordCount() == 1)
    }

    @Test func knownPostUpdateVersionIsPersistedForEveryRecoveryObligation() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let first = fixture.target(id: "version-first")
        let second = fixture.target(id: "version-second")
        let harness = TestUpdaterHarness(
            targets: [first, second],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .allOpen)
        _ = await operation.result()
        let persistedTargets = Set(
            await harness.savedRecords()
                .filter {
                    $0.stage == .shellReady && $0.versionAfter == fixture.versionAfter
                }
                .map { $0.target.id }
        )

        #expect(persistedTargets == [first.id, second.id])
    }

    @Test func rejectsAConcurrentOperationBeforeAnySecondDiscovery() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "lease")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            pauseAtShell: true
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let firstOperation = try await orchestrator.start(scope: .selected(target.id))
        var iterator = firstOperation.progress.makeAsyncIterator()
        while let snapshot = await iterator.next() {
            if snapshot.targetPhases[target.id] == .waitingForShell { break }
        }

        do {
            _ = try await orchestrator.start(scope: .selected(target.id))
            Issue.record("Expected the active operation lease to reject a second start")
        } catch let error as ClaudeUpdateOrchestratorError {
            #expect(error == .operationAlreadyRunning)
        }

        firstOperation.cancel()
        await harness.releaseShell()
        _ = await firstOperation.result()
    }

    @Test func pendingJournalBlocksUpdateUntilExactRecoverySucceeds() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "recovery")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )
        let interruptedOperationID = UUID()
        let timestamp = await harness.now()
        try await harness.save(
            ClaudeUpdateRecoveryRecord(
                operationID: interruptedOperationID,
                target: target,
                stage: .shellReady,
                observedProcessID: 42,
                versionBefore: fixture.versionBefore,
                updatedAt: timestamp
            )
        )

        do {
            _ = try await orchestrator.start(scope: .selected(target.id))
            Issue.record("Expected pending recovery to block a new update")
        } catch let error as ClaudeUpdateOrchestratorError {
            #expect(error == .recoveryRequired(recordCount: 1))
        }

        let outcomes = try await orchestrator.recoverPendingSessions()
        let pendingRecordCount = await harness.pendingRecordCount()

        #expect(outcomes.map(\.status) == [.restored])
        #expect(await harness.replacingProcessID(for: target.id) == 42)
        #expect(pendingRecordCount == 0)
    }

    @Test func recoveryReconcilesAndPersistsAnUnknownPostUpdateVersion() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "unknown-version")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            initialInstalledVersion: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )
        let operationID = UUID()
        try await harness.save(
            ClaudeUpdateRecoveryRecord(
                operationID: operationID,
                target: target,
                stage: .shellReady,
                observedProcessID: 42,
                versionBefore: fixture.versionBefore,
                updatedAt: await harness.now()
            )
        )

        let outcomes = try await orchestrator.recoverPendingSessions()
        let reconciledRecords = await harness.savedRecords().filter {
            $0.operationID == operationID && $0.versionAfter == fixture.versionAfter
        }

        #expect(outcomes.first?.status == .restored)
        #expect(outcomes.first?.versionAfter == fixture.versionAfter)
        #expect(!reconciledRecords.isEmpty)
        #expect(await harness.pendingRecordCount() == 0)
    }

    @Test func recoveryRejectsARecordedVersionThatDisagreesWithTheLiveInstallation() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let target = fixture.target(id: "ambiguous-version")
        let harness = TestUpdaterHarness(
            targets: [target],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter,
            initialInstalledVersion: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )
        try await harness.save(
            ClaudeUpdateRecoveryRecord(
                operationID: UUID(),
                target: target,
                stage: .restorationStarted,
                observedProcessID: 42,
                versionBefore: fixture.versionBefore,
                versionAfter: fixture.versionBefore,
                updatedAt: await harness.now()
            )
        )

        let outcomes = try await orchestrator.recoverPendingSessions()

        #expect(outcomes.first?.status == .failed)
        #expect(outcomes.first?.issue == .restorationVerificationFailed)
        #expect(await harness.restoreCallCount() == 1)
        #expect(await harness.pendingRecordCount() == 1)
    }

    @Test func confirmedPlanNeverRediscoversOrIncludesTargetsAddedAfterPreview() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let confirmedTarget = fixture.target(id: "confirmed")
        let laterTarget = fixture.target(id: "opened-later")
        let confirmedPlan = try ClaudeUpdatePlan(
            scope: .allOpen,
            targets: [confirmedTarget]
        )
        let harness = TestUpdaterHarness(
            targets: [confirmedTarget, laterTarget],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(confirmedPlan: confirmedPlan)
        let summary = await operation.result()
        let events = await harness.recordedEvents()

        #expect(await harness.targetDiscoveryCount() == 0)
        #expect(summary.plan == confirmedPlan)
        #expect(summary.outcomes.map(\.targetID) == [confirmedTarget.id])
        #expect(!events.contains("exit:\(laterTarget.id.rawValue)"))
    }

    @Test func executesOnceForEachInstallationAndKeepsBothHostOutcomes() async throws {
        let fixture = ClaudeUpdateTestFixture()
        let native = fixture.target(id: "native")
        let npm = fixture.target(
            id: "npm",
            installationID: "npm:/usr/local/lib/node_modules/claude",
            executablePath: "/usr/local/bin/claude"
        )
        let harness = TestUpdaterHarness(
            targets: [native, npm],
            versionBefore: fixture.versionBefore,
            versionAfter: fixture.versionAfter
        )
        let orchestrator = ClaudeUpdateOrchestrator(
            targetProvider: harness,
            sessionController: harness,
            binaryUpdater: harness,
            journal: harness,
            clock: harness,
            logger: harness
        )

        let operation = try await orchestrator.start(scope: .allOpen)
        let summary = await operation.result()

        #expect(await harness.updateCallCount() == 2)
        #expect(summary.hostOutcomes.count == 2)
        #expect(Set(summary.hostOutcomes.map(\.id)).count == 2)
        #expect(Set(summary.hostOutcomes.compactMap(\.installationID)) == [
            "native:/opt/claude",
            "npm:/usr/local/lib/node_modules/claude",
        ])
    }
}
