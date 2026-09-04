import Foundation

/// Coordinates preflight, checkpointing, mutation, durable persistence, verification, and rollback.
@MainActor
struct UniConnectImportTransaction {
    private let journal: any UniConnectImportJournalWriting
    private let tmuxVerifier: any UniConnectExistingTmuxVerifying
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> TimeInterval

    init(
        journal: any UniConnectImportJournalWriting,
        tmuxVerifier: any UniConnectExistingTmuxVerifying,
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.journal = journal
        self.tmuxVerifier = tmuxVerifier
        self.makeID = makeID
        self.now = now
    }

    func execute(
        prepared: UniConnectPreparedImport,
        selection: UniConnectImportSelection,
        adapter: any UniConnectImportTransactionApplying
    ) async -> UniConnectImportTransactionResult {
        let mutations: [UniConnectImportMutation]
        do {
            mutations = try prepared.mutations(for: selection)
        } catch {
            return .failedBeforeMutation(.invalidSelection)
        }
        if let failure = await prepareJournalForNewTransaction(adapter: adapter) {
            return .failedBeforeMutation(failure)
        }
        guard !mutations.isEmpty else { return .noChanges }
        guard await stateStillMatches(prepared: prepared, adapter: adapter) else {
            return .failedBeforeMutation(.stateChanged)
        }

        let requirements: [UniConnectExistingTmuxRequirement]
        do {
            requirements = try prepared.existingTmuxRequirements(for: selection)
        } catch {
            return .failedBeforeMutation(.invalidSelection)
        }
        let verification = await tmuxVerifier.verify(requirements)
        guard !Task.isCancelled else {
            return .failedBeforeMutation(.cancelled)
        }
        let unavailable = verification.filter { $0.status == .unavailable }.map(\.windowID)
        guard unavailable.isEmpty else {
            return .failedBeforeMutation(.remoteSessionsUnavailable(unavailable))
        }
        // A preflight can take seconds. Reconcile again before the first mutation.
        guard await stateStillMatches(prepared: prepared, adapter: adapter) else {
            return .failedBeforeMutation(.stateChanged)
        }

        let baselineStateToken: String
        do {
            baselineStateToken = try await adapter.currentStateToken()
        } catch {
            return .failedBeforeMutation(.stateChanged)
        }

        let transactionID = makeID()
        let checkpointID = makeID()
        do {
            try await adapter.createCheckpoint(id: checkpointID)
        } catch {
            return .failedBeforeMutation(.checkpointFailed)
        }
        do {
            guard try await adapter.currentStateToken() == baselineStateToken else {
                try? await adapter.deleteCheckpoint(id: checkpointID)
                return .failedBeforeMutation(.stateChanged)
            }
        } catch {
            try? await adapter.deleteCheckpoint(id: checkpointID)
            return .failedBeforeMutation(.stateChanged)
        }

        var expectedStateToken = baselineStateToken

        var record = UniConnectImportJournalRecord(
            transactionID: transactionID,
            checkpointID: checkpointID,
            sourceDigest: prepared.sourceDigest,
            selectedRowIDs: selection.rowIDs.sorted(),
            completedRowIDs: [],
            nextRowID: nil,
            expectedStateToken: expectedStateToken,
            phase: .prepared,
            createdAt: now(),
            updatedAt: now()
        )
        do {
            try await journal.save(record)
        } catch {
            return await rollback(
                transactionID: transactionID,
                checkpointID: checkpointID,
                record: &record,
                failure: .journalFailed,
                adapter: adapter
            )
        }

        for mutation in mutations {
            if Task.isCancelled {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .cancelled,
                    adapter: adapter
                )
            }
            guard await stateTokenMatches(expectedStateToken, adapter: adapter) else {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .stateChanged,
                    adapter: adapter
                )
            }
            record.phase = .applying
            record.nextRowID = mutation.rowID
            record.updatedAt = now()
            do {
                try await journal.save(record)
            } catch {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .journalFailed,
                    adapter: adapter
                )
            }
            do {
                try await adapter.apply(mutation)
                expectedStateToken = try await adapter.currentStateToken()
                record.expectedStateToken = expectedStateToken
            } catch {
                // `apply` is one main-actor critical section. Any partial graph it
                // produced still belongs to this transaction and is safe to undo.
                if let partialToken = try? await adapter.currentStateToken() {
                    expectedStateToken = partialToken
                    record.expectedStateToken = partialToken
                }
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .mutationFailed(rowID: mutation.rowID),
                    adapter: adapter
                )
            }
            do {
                guard try await adapter.verifyApplied(mutation) else {
                    return await rollback(
                        transactionID: transactionID,
                        checkpointID: checkpointID,
                        record: &record,
                        failure: .mutationFailed(rowID: mutation.rowID),
                        adapter: adapter
                    )
                }
                guard await stateTokenMatches(expectedStateToken, adapter: adapter) else {
                    return await rollback(
                        transactionID: transactionID,
                        checkpointID: checkpointID,
                        record: &record,
                        failure: .stateChanged,
                        adapter: adapter
                    )
                }
                try await adapter.finalizeVerified(mutation)
                expectedStateToken = try await adapter.currentStateToken()
                record.expectedStateToken = expectedStateToken
            } catch {
                if let partialToken = try? await adapter.currentStateToken() {
                    expectedStateToken = partialToken
                    record.expectedStateToken = partialToken
                }
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .mutationFailed(rowID: mutation.rowID),
                    adapter: adapter
                )
            }
            record.completedRowIDs.append(mutation.rowID)
            record.nextRowID = nil
            record.updatedAt = now()
            do {
                try await journal.save(record)
            } catch {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .journalFailed,
                    adapter: adapter
                )
            }
        }

        record.phase = .persisting
        record.updatedAt = now()
        guard await stateTokenMatches(expectedStateToken, adapter: adapter) else {
            return await rollback(
                transactionID: transactionID,
                checkpointID: checkpointID,
                record: &record,
                failure: .stateChanged,
                adapter: adapter
            )
        }
        do {
            try await journal.save(record)
            try await adapter.persistDurably()
            expectedStateToken = try await adapter.currentStateToken()
            record.expectedStateToken = expectedStateToken
        } catch {
            return await rollback(
                transactionID: transactionID,
                checkpointID: checkpointID,
                record: &record,
                failure: .persistenceFailed,
                adapter: adapter
            )
        }

        do {
            guard try await adapter.verifyCommitted(mutations) else {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .verificationFailed,
                    adapter: adapter
                )
            }
            guard await stateTokenMatches(expectedStateToken, adapter: adapter) else {
                return await rollback(
                    transactionID: transactionID,
                    checkpointID: checkpointID,
                    record: &record,
                    failure: .stateChanged,
                    adapter: adapter
                )
            }
        } catch {
            return await rollback(
                transactionID: transactionID,
                checkpointID: checkpointID,
                record: &record,
                failure: .verificationFailed,
                adapter: adapter
            )
        }

        record.phase = .committed
        record.updatedAt = now()
        do {
            try await journal.save(record)
        } catch {
            // Never report success while the last durable journal phase still says
            // `persisting`; startup recovery would correctly treat that as interrupted.
            return await rollback(
                transactionID: transactionID,
                checkpointID: checkpointID,
                record: &record,
                failure: .journalFailed,
                adapter: adapter
            )
        }
        // Delete the encrypted recovery boundary before clearing its terminal journal.
        // A cleanup failure leaves the terminal journal available for a safe startup retry.
        _ = await cleanupTerminalRecord(record, adapter: adapter)
        return .committed(transactionID: transactionID, mutatedRowIDs: record.completedRowIDs)
    }

    /// Rolls back an interrupted, non-committed transaction found at startup.
    func recoverInterruptedTransaction(
        adapter: any UniConnectImportTransactionApplying
    ) async -> UniConnectImportTransactionResult? {
        let existing: UniConnectImportJournalRecord
        do {
            guard let loaded = try await journal.load() else {
                await pruneStaleCheckpoints(adapter: adapter)
                return nil
            }
            existing = loaded
        } catch {
            return .failedBeforeMutation(.journalFailed)
        }
        if existing.phase == .committed || existing.phase == .rollbackComplete {
            if await cleanupTerminalRecord(existing, adapter: adapter) {
                await pruneStaleCheckpoints(adapter: adapter)
                return .noChanges
            }
            return .failedBeforeMutation(.checkpointFailed)
        }
        var record = existing
        let result = await rollback(
            transactionID: existing.transactionID,
            checkpointID: existing.checkpointID,
            record: &record,
            failure: .cancelled,
            adapter: adapter
        )
        if case .rolledBack = result {
            await pruneStaleCheckpoints(adapter: adapter)
        }
        return result
    }

    private func stateStillMatches(
        prepared: UniConnectPreparedImport,
        adapter: any UniConnectImportTransactionApplying
    ) async -> Bool {
        guard let current = try? await adapter.currentDocument() else { return false }
        return prepared.refreshedPlan(against: current) == prepared.plan
    }

    private func stateTokenMatches(
        _ expected: String,
        adapter: any UniConnectImportTransactionApplying
    ) async -> Bool {
        guard let current = try? await adapter.currentStateToken() else { return false }
        return current == expected
    }

    private func prepareJournalForNewTransaction(
        adapter: any UniConnectImportTransactionApplying
    ) async -> UniConnectImportTransactionResult.Failure? {
        let existing: UniConnectImportJournalRecord
        do {
            guard let loaded = try await journal.load() else { return nil }
            existing = loaded
        } catch {
            return .journalFailed
        }
        guard existing.phase == .committed || existing.phase == .rollbackComplete else {
            return .journalFailed
        }
        guard await cleanupTerminalRecord(existing, adapter: adapter) else {
            return .checkpointFailed
        }
        await pruneStaleCheckpoints(adapter: adapter)
        return nil
    }

    private func rollback(
        transactionID: UUID,
        checkpointID: UUID,
        record: inout UniConnectImportJournalRecord,
        failure: UniConnectImportTransactionResult.Failure,
        adapter: any UniConnectImportTransactionApplying
    ) async -> UniConnectImportTransactionResult {
        record.phase = .rollingBack
        record.updatedAt = now()
        try? await journal.save(record)
        do {
            try await adapter.rollback(
                to: checkpointID,
                expectedStateToken: record.expectedStateToken
            )
            try await adapter.persistDurably()
            guard try await adapter.verifyRolledBack(to: checkpointID) else {
                return .rollbackFailed(transactionID: transactionID, originalFailure: failure)
            }
        } catch {
            return .rollbackFailed(transactionID: transactionID, originalFailure: failure)
        }
        record.phase = .rollbackComplete
        record.nextRowID = nil
        record.updatedAt = now()
        do {
            try await journal.save(record)
            _ = await cleanupTerminalRecord(record, adapter: adapter)
        } catch {
            // Keep the checkpoint if the terminal phase cannot be recorded. Startup
            // will replay the idempotent rollback instead of losing its recovery data.
        }
        return .rolledBack(transactionID: transactionID, failure: failure)
    }

    private func cleanupTerminalRecord(
        _ record: UniConnectImportJournalRecord,
        adapter: any UniConnectImportTransactionApplying
    ) async -> Bool {
        do {
            try await adapter.deleteCheckpoint(id: record.checkpointID)
            try await journal.clear(transactionID: record.transactionID)
            return true
        } catch {
            return false
        }
    }

    private func pruneStaleCheckpoints(
        adapter: any UniConnectImportTransactionApplying
    ) async {
        let retention: TimeInterval = 7 * 24 * 60 * 60
        await adapter.pruneCheckpoints(
            olderThan: Date(timeIntervalSince1970: now() - retention)
        )
    }
}
