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

        #expect(outcome.status == .restored)
        #expect(outcome.issue == .updateCommandFailed)
        #expect(events.contains(where: { $0.hasPrefix("update:") }))
        #expect(events.contains("restore:\(target.id.rawValue)"))
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
        #expect(pendingRecordCount == 0)
    }
}
