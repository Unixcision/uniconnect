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
}
