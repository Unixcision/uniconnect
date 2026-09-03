import Foundation

/// An actor-backed state machine that safely updates and restores Claude sessions.
///
/// The orchestrator performs no terminal, process, SSH, filesystem, or credential work itself.
/// It sequences constructor-injected boundaries, publishes immutable progress snapshots, and owns
/// the invariant that every durably armed exit is followed by cancellation-resistant restoration.
public actor ClaudeUpdateOrchestrator {
    private let targetProvider: any ClaudeUpdateTargetProviding
    private let sessionController: any ClaudeSessionControlling
    private let binaryUpdater: any ClaudeBinaryUpdating
    private let journal: any ClaudeUpdateJournaling
    private let clock: any ClaudeUpdateClock
    private let logger: any ClaudeUpdateLogging
    private let outputParser: ClaudeUpdateOutputParser

    private var activeOperationID: UUID?
    private var activeTask: Task<ClaudeUpdateSummary, Never>?
    private var executionContext: ClaudeUpdateExecutionContext?

    /// Creates an updater state machine from application-owned capability adapters.
    ///
    /// ```swift
    /// let updater = ClaudeUpdateOrchestrator(
    ///     targetProvider: targetSource,
    ///     sessionController: sessions,
    ///     binaryUpdater: binaries,
    ///     journal: recoveryJournal,
    ///     clock: SystemClaudeUpdateClock(),
    ///     logger: updateLog
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - targetProvider: Read-only discovery of visible targets.
    ///   - sessionController: Exact local or SSH/tmux session control.
    ///   - binaryUpdater: Controlled version and update process execution.
    ///   - journal: Durable restoration obligations.
    ///   - clock: Deterministic timestamps.
    ///   - logger: Structured credential-free event logging.
    ///   - outputParser: Pure output assessment, injectable for explicit composition.
    public init(
        targetProvider: any ClaudeUpdateTargetProviding,
        sessionController: any ClaudeSessionControlling,
        binaryUpdater: any ClaudeBinaryUpdating,
        journal: any ClaudeUpdateJournaling,
        clock: any ClaudeUpdateClock,
        logger: any ClaudeUpdateLogging,
        outputParser: ClaudeUpdateOutputParser = ClaudeUpdateOutputParser()
    ) {
        self.targetProvider = targetProvider
        self.sessionController = sessionController
        self.binaryUpdater = binaryUpdater
        self.journal = journal
        self.clock = clock
        self.logger = logger
        self.outputParser = outputParser
    }

    /// Resolves a scope, validates conflicts, and starts one asynchronous update operation.
    ///
    /// Target discovery and plan validation finish before the returned operation can mutate a
    /// session. The operation's `AsyncStream` buffers every state transition for deterministic UI
    /// projection and tests.
    ///
    /// - Parameters:
    ///   - scope: The selected target, box, or all-open scope.
    ///   - operationID: A caller-supplied identifier, defaulting to a fresh UUID.
    /// - Returns: A cancellable operation with progress and final result surfaces.
    /// - Throws: ``ClaudeUpdateOrchestratorError/operationAlreadyRunning``, a discovery error, or
    ///   ``ClaudeUpdatePlanError`` before mutation starts.
    public func start(
        scope: ClaudeUpdateScope,
        operationID: UUID = UUID()
    ) async throws -> ClaudeUpdateOperation {
        guard activeOperationID == nil else {
            throw ClaudeUpdateOrchestratorError.operationAlreadyRunning
        }
        activeOperationID = operationID

        do {
            let targets = try await targetProvider.targets(for: scope)
            try Task.checkCancellation()
            let plan = try ClaudeUpdatePlan(id: operationID, scope: scope, targets: targets)
            let startedAt = await clock.now()
            try Task.checkCancellation()
            let pair = AsyncStream<ClaudeUpdateProgress>.makeStream(bufferingPolicy: .unbounded)
            executionContext = ClaudeUpdateExecutionContext(
                plan: plan,
                startedAt: startedAt,
                continuation: pair.continuation
            )
            pair.continuation.yield(executionContext?.snapshot ?? ClaudeUpdateProgress(
                operationID: operationID,
                scope: scope,
                phase: .preflight,
                currentHost: nil,
                currentTargetID: nil,
                targetPhases: [:],
                outcomes: [],
                hostOutcomes: [],
                isCancellationRequested: false
            ))

            let task = Task {
                await self.execute(plan: plan, startedAt: startedAt)
            }
            activeTask = task
            return ClaudeUpdateOperation(id: operationID, progress: pair.stream, resultTask: task)
        } catch {
            activeOperationID = nil
            executionContext = nil
            throw error
        }
    }

    /// Requests cancellation of the active operation, if one exists.
    ///
    /// New exits and updates stop at the next suspension boundary. Already-journaled targets keep
    /// their unconditional restoration obligation.
    public func cancelActiveOperation() {
        activeTask?.cancel()
        guard executionContext != nil else { return }
        executionContext?.cancellationRequested = true
        if let snapshot = executionContext?.snapshot {
            executionContext?.continuation.yield(snapshot)
        }
    }

    /// Returns the latest immutable snapshot for a currently running operation.
    ///
    /// - Returns: Current progress, or `nil` when no operation is active.
    public func activeProgress() -> ClaudeUpdateProgress? {
        executionContext?.snapshot
    }

    /// Restores durable obligations left by termination or a previous interrupted launch.
    ///
    /// Every record is reconciled idempotently and verified against the expected UUID, cwd, and
    /// executable. A record remains durable when either restoration, verification, or removal
    /// fails. Recovery intentionally ignores caller cancellation once records have been loaded.
    ///
    /// - Returns: One restoration or failure outcome per pending record.
    /// - Throws: ``ClaudeUpdateOrchestratorError/operationAlreadyRunning`` or a journal load error.
    public func recoverPendingSessions() async throws -> [ClaudeUpdateOutcome] {
        guard activeOperationID == nil else {
            throw ClaudeUpdateOrchestratorError.operationAlreadyRunning
        }
        activeOperationID = UUID()
        defer { activeOperationID = nil }

        let records = try await journal.pendingRecords()
        var outcomes: [ClaudeUpdateOutcome] = []

        for record in records {
            let target = record.target
            let sessions = sessionController
            let didRestore = await Task.detached(priority: .userInitiated) {
                do {
                    try await sessions.restore(target)
                    return true
                } catch {
                    return false
                }
            }.value

            guard didRestore else {
                let outcome = ClaudeUpdateOutcome(
                    targetID: target.id,
                    host: target.host,
                    status: .failed,
                    issue: .restorationFailed,
                    versionBefore: record.versionBefore
                )
                outcomes.append(outcome)
                await log(
                    operationID: record.operationID,
                    level: .error,
                    phase: .restoring,
                    host: target.host,
                    targetID: target.id,
                    issue: .restorationFailed
                )
                continue
            }

            let inspection = await Task.detached(priority: .userInitiated) {
                try? await sessions.inspect(target)
            }.value
            guard let inspection, inspection.processID != nil, inspection.matches(target) else {
                let outcome = ClaudeUpdateOutcome(
                    targetID: target.id,
                    host: target.host,
                    status: .failed,
                    issue: .restorationVerificationFailed,
                    versionBefore: record.versionBefore
                )
                outcomes.append(outcome)
                await log(
                    operationID: record.operationID,
                    level: .error,
                    phase: .verifyingSession,
                    host: target.host,
                    targetID: target.id,
                    issue: .restorationVerificationFailed
                )
                continue
            }

            let recoveryJournal = journal
            let didRemoveRecord = await Task.detached(priority: .userInitiated) {
                do {
                    try await recoveryJournal.remove(
                        operationID: record.operationID,
                        targetID: target.id
                    )
                    return true
                } catch {
                    return false
                }
            }.value
            outcomes.append(
                ClaudeUpdateOutcome(
                    targetID: target.id,
                    host: target.host,
                    status: .restored,
                    issue: didRemoveRecord ? nil : .journalUnavailable,
                    versionBefore: record.versionBefore
                )
            )
        }
        return outcomes
    }

    private func execute(plan: ClaudeUpdatePlan, startedAt: Date) async -> ClaudeUpdateSummary {
        var wasCancelled = false

        for hostPlan in plan.hosts {
            if Task.isCancelled {
                wasCancelled = true
                await markCancellation()
                break
            }
            if await execute(hostPlan: hostPlan, operationID: plan.id) {
                wasCancelled = true
                break
            }
        }

        if Task.isCancelled {
            wasCancelled = true
            await markCancellation()
        }
        await recordUnfinishedTargets(
            in: plan.targets,
            status: .skipped,
            issue: wasCancelled ? .cancelled : .inspectionFailed
        )

        let finishedAt = await clock.now()
        if executionContext != nil {
            executionContext?.transition(host: nil, targetID: nil, phase: .completed)
            executionContext?.cancellationRequested = wasCancelled
            if let snapshot = executionContext?.snapshot {
                executionContext?.continuation.yield(snapshot)
            }
        }

        let outcomes = executionContext?.outcomes ?? []
        let hostOutcomes = executionContext?.hostOutcomes ?? []
        let summary = ClaudeUpdateSummary(
            plan: plan,
            outcomes: outcomes,
            hostOutcomes: hostOutcomes,
            startedAt: startedAt,
            finishedAt: finishedAt,
            wasCancelled: wasCancelled
        )
        executionContext?.continuation.finish()
        executionContext = nil
        activeTask = nil
        activeOperationID = nil
        return summary
    }

    private func execute(
        hostPlan: ClaudeUpdateHostPlan,
        operationID: UUID
    ) async -> Bool {
        var readyTargets: [(target: ClaudeUpdateTarget, processID: Int32)] = []
        var firstPreflightIssue: ClaudeUpdateIssue?

        for target in hostPlan.targets {
            if Task.isCancelled {
                await markCancellation()
                await recordUnfinishedTargets(in: hostPlan.targets, status: .skipped, issue: .cancelled)
                await recordHostOutcome(
                    ClaudeUpdateHostOutcome(host: hostPlan.host, status: .skipped, issue: .cancelled),
                    operationID: operationID
                )
                return true
            }

            await transition(
                operationID: operationID,
                host: hostPlan.host,
                targetID: target.id,
                phase: .preflight
            )

            guard hasUsableBinding(target) else {
                firstPreflightIssue = firstPreflightIssue ?? .missingSessionBinding
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .skipped,
                        issue: .missingSessionBinding
                    ),
                    operationID: operationID
                )
                continue
            }
            guard hasValidShape(target) else {
                let issue: ClaudeUpdateIssue = target.host.kind == .remote
                    ? .missingPaneIdentity
                    : .invalidTargetShape
                firstPreflightIssue = firstPreflightIssue ?? issue
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .skipped,
                        issue: issue
                    ),
                    operationID: operationID
                )
                continue
            }

            let initialInspection: ClaudeSessionInspection
            do {
                initialInspection = try await sessionController.inspect(target)
            } catch {
                let issue: ClaudeUpdateIssue = Task.isCancelled ? .cancelled : .inspectionFailed
                firstPreflightIssue = firstPreflightIssue ?? issue
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .skipped,
                        issue: issue
                    ),
                    operationID: operationID
                )
                if Task.isCancelled {
                    await markCancellation()
                    await recordUnfinishedTargets(in: hostPlan.targets, status: .skipped, issue: .cancelled)
                    await recordHostOutcome(
                        ClaudeUpdateHostOutcome(host: hostPlan.host, status: .skipped, issue: .cancelled),
                        operationID: operationID
                    )
                    return true
                }
                continue
            }

            guard
                let processID = initialInspection.processID,
                initialInspection.matches(target)
            else {
                firstPreflightIssue = firstPreflightIssue ?? .processIdentityMismatch
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .skipped,
                        issue: .processIdentityMismatch
                    ),
                    operationID: operationID
                )
                continue
            }

            await transition(
                operationID: operationID,
                host: hostPlan.host,
                targetID: target.id,
                phase: .waitingForIdle
            )
            do {
                let readyInspection = try await sessionController.waitUntilReadyForExit(target)
                guard
                    readyInspection.isIdle,
                    readyInspection.processID == processID,
                    readyInspection.matches(target)
                else {
                    firstPreflightIssue = firstPreflightIssue ?? .processIdentityMismatch
                    await recordTargetOutcome(
                        ClaudeUpdateOutcome(
                            targetID: target.id,
                            host: target.host,
                            status: .skipped,
                            issue: .processIdentityMismatch
                        ),
                        operationID: operationID
                    )
                    continue
                }
                readyTargets.append((target, processID))
            } catch {
                let issue: ClaudeUpdateIssue = Task.isCancelled ? .cancelled : .idleTimeout
                firstPreflightIssue = firstPreflightIssue ?? issue
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .skipped,
                        issue: issue
                    ),
                    operationID: operationID
                )
                if Task.isCancelled {
                    await markCancellation()
                    await recordUnfinishedTargets(in: hostPlan.targets, status: .skipped, issue: .cancelled)
                    await recordHostOutcome(
                        ClaudeUpdateHostOutcome(host: hostPlan.host, status: .skipped, issue: .cancelled),
                        operationID: operationID
                    )
                    return true
                }
            }
        }

        guard
            !readyTargets.isEmpty,
            let executablePath = hostPlan.executablePath
        else {
            await recordHostOutcome(
                ClaudeUpdateHostOutcome(
                    host: hostPlan.host,
                    status: .skipped,
                    issue: firstPreflightIssue ?? .missingSessionBinding
                ),
                operationID: operationID
            )
            return false
        }

        let versionBefore: ClaudeVersion
        do {
            versionBefore = try await binaryUpdater.installedVersion(
                on: hostPlan.host,
                executablePath: executablePath
            )
        } catch {
            let issue: ClaudeUpdateIssue = Task.isCancelled ? .cancelled : .versionReadFailed
            if Task.isCancelled { await markCancellation() }
            await recordUnfinishedTargets(
                in: readyTargets.map { $0.target },
                status: Task.isCancelled ? .skipped : .failed,
                issue: issue
            )
            await recordHostOutcome(
                ClaudeUpdateHostOutcome(
                    host: hostPlan.host,
                    status: Task.isCancelled ? .skipped : .failed,
                    issue: issue
                ),
                operationID: operationID
            )
            return Task.isCancelled
        }

        var obligations: [(target: ClaudeUpdateTarget, processID: Int32)] = []
        var operationIssue: ClaudeUpdateIssue?

        for readyTarget in readyTargets {
            if Task.isCancelled {
                operationIssue = .cancelled
                await markCancellation()
                break
            }

            let timestamp = await clock.now()
            let record = ClaudeUpdateRecoveryRecord(
                operationID: operationID,
                target: readyTarget.target,
                stage: .exitRequested,
                observedProcessID: readyTarget.processID,
                versionBefore: versionBefore,
                updatedAt: timestamp
            )
            do {
                try await journal.save(record)
            } catch {
                operationIssue = Task.isCancelled ? .cancelled : .journalUnavailable
                if Task.isCancelled { await markCancellation() }
                break
            }
            obligations.append(readyTarget)

            await transition(
                operationID: operationID,
                host: hostPlan.host,
                targetID: readyTarget.target.id,
                phase: .requestingExit
            )
            do {
                try await sessionController.requestCleanExit(
                    readyTarget.target,
                    expectedProcessID: readyTarget.processID
                )
            } catch {
                operationIssue = Task.isCancelled ? .cancelled : .exitRequestFailed
                if Task.isCancelled { await markCancellation() }
                break
            }

            await transition(
                operationID: operationID,
                host: hostPlan.host,
                targetID: readyTarget.target.id,
                phase: .waitingForShell
            )
            do {
                try await sessionController.waitForShellAfterExit(
                    readyTarget.target,
                    exitedProcessID: readyTarget.processID
                )
            } catch {
                operationIssue = Task.isCancelled ? .cancelled : .shellTimeout
                if Task.isCancelled { await markCancellation() }
                break
            }

            let shellTimestamp = await clock.now()
            let shellRecord = ClaudeUpdateRecoveryRecord(
                operationID: operationID,
                target: readyTarget.target,
                stage: .shellReady,
                observedProcessID: readyTarget.processID,
                versionBefore: versionBefore,
                updatedAt: shellTimestamp
            )
            try? await journal.save(shellRecord)
        }

        if operationIssue != nil {
            let obligationIDs = Set(obligations.map { $0.target.id })
            let unarmedTargets = readyTargets
                .map { $0.target }
                .filter { !obligationIDs.contains($0.id) }
            await recordUnfinishedTargets(
                in: unarmedTargets,
                status: operationIssue == .cancelled ? .skipped : .failed,
                issue: operationIssue ?? .inspectionFailed,
                versionBefore: versionBefore
            )
        }

        guard !obligations.isEmpty else {
            let issue = operationIssue ?? .journalUnavailable
            await recordHostOutcome(
                ClaudeUpdateHostOutcome(
                    host: hostPlan.host,
                    status: issue == .cancelled ? .skipped : .failed,
                    issue: issue,
                    versionBefore: versionBefore
                ),
                operationID: operationID
            )
            return issue == .cancelled
        }

        var command: ClaudeUpdateCommandResult?
        var versionAfter: ClaudeVersion?
        var assessment: ClaudeBinaryUpdateAssessment?

        if operationIssue == nil, !Task.isCancelled {
            for obligation in obligations {
                await transition(
                    operationID: operationID,
                    host: hostPlan.host,
                    targetID: obligation.target.id,
                    phase: .updating
                )
            }
            do {
                command = try await binaryUpdater.update(
                    on: hostPlan.host,
                    executablePath: executablePath
                )
            } catch {
                operationIssue = Task.isCancelled ? .cancelled : .updateCommandFailed
                if Task.isCancelled { await markCancellation() }
            }

            if operationIssue == nil, !Task.isCancelled, let command {
                for obligation in obligations {
                    await transition(
                        operationID: operationID,
                        host: hostPlan.host,
                        targetID: obligation.target.id,
                        phase: .verifyingUpdate
                    )
                }
                do {
                    versionAfter = try await binaryUpdater.installedVersion(
                        on: hostPlan.host,
                        executablePath: executablePath
                    )
                    assessment = outputParser.assess(
                        command: command,
                        before: versionBefore,
                        after: versionAfter
                    )
                    if assessment?.status == .failed {
                        operationIssue = assessment?.issue ?? .updateUnverifiable
                    }
                } catch {
                    operationIssue = Task.isCancelled ? .cancelled : .versionReadFailed
                    if Task.isCancelled { await markCancellation() }
                }
            }
        } else if Task.isCancelled {
            operationIssue = .cancelled
            await markCancellation()
        }

        let desiredStatus: ClaudeUpdateOutcomeStatus?
        switch assessment?.status {
        case .updated:
            desiredStatus = .updated
        case .alreadyUpdated:
            desiredStatus = .alreadyUpdated
        case .failed, nil:
            desiredStatus = nil
        }

        let restoration = await restore(
            obligations: obligations,
            operationID: operationID,
            versionBefore: versionBefore,
            versionAfter: versionAfter,
            desiredStatus: desiredStatus,
            operationIssue: operationIssue
        )

        let hostStatus: ClaudeUpdateOutcomeStatus
        let hostIssue: ClaudeUpdateIssue?
        if !restoration.allSessionsVerified {
            hostStatus = .failed
            hostIssue = .restorationFailed
        } else if !restoration.journalIsClean {
            hostStatus = .restored
            hostIssue = .journalUnavailable
        } else if let desiredStatus {
            hostStatus = desiredStatus
            hostIssue = nil
        } else {
            hostStatus = .restored
            hostIssue = operationIssue ?? .updateUnverifiable
        }

        await recordHostOutcome(
            ClaudeUpdateHostOutcome(
                host: hostPlan.host,
                status: hostStatus,
                issue: hostIssue,
                versionBefore: versionBefore,
                versionAfter: versionAfter,
                command: command
            ),
            operationID: operationID
        )
        return operationIssue == .cancelled || Task.isCancelled
    }

    private func restore(
        obligations: [(target: ClaudeUpdateTarget, processID: Int32)],
        operationID: UUID,
        versionBefore: ClaudeVersion,
        versionAfter: ClaudeVersion?,
        desiredStatus: ClaudeUpdateOutcomeStatus?,
        operationIssue: ClaudeUpdateIssue?
    ) async -> (allSessionsVerified: Bool, journalIsClean: Bool) {
        var allSessionsVerified = true
        var journalIsClean = true

        for obligation in obligations {
            let target = obligation.target
            await transition(
                operationID: operationID,
                host: target.host,
                targetID: target.id,
                phase: .restoring
            )

            let timestamp = await clock.now()
            let restoringRecord = ClaudeUpdateRecoveryRecord(
                operationID: operationID,
                target: target,
                stage: .restorationStarted,
                observedProcessID: obligation.processID,
                versionBefore: versionBefore,
                updatedAt: timestamp
            )
            let recoveryJournal = journal
            _ = await Task.detached(priority: .userInitiated) {
                try? await recoveryJournal.save(restoringRecord)
            }.value

            let sessions = sessionController
            let didRestore = await Task.detached(priority: .userInitiated) {
                do {
                    try await sessions.restore(target)
                    return true
                } catch {
                    return false
                }
            }.value
            guard didRestore else {
                allSessionsVerified = false
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .failed,
                        issue: .restorationFailed,
                        versionBefore: versionBefore,
                        versionAfter: versionAfter
                    ),
                    operationID: operationID
                )
                continue
            }

            await transition(
                operationID: operationID,
                host: target.host,
                targetID: target.id,
                phase: .verifyingSession
            )
            let inspection = await Task.detached(priority: .userInitiated) {
                try? await sessions.inspect(target)
            }.value
            guard let inspection, inspection.processID != nil, inspection.matches(target) else {
                allSessionsVerified = false
                await recordTargetOutcome(
                    ClaudeUpdateOutcome(
                        targetID: target.id,
                        host: target.host,
                        status: .failed,
                        issue: .restorationVerificationFailed,
                        versionBefore: versionBefore,
                        versionAfter: versionAfter
                    ),
                    operationID: operationID
                )
                continue
            }

            let didRemoveRecord = await Task.detached(priority: .userInitiated) {
                do {
                    try await recoveryJournal.remove(operationID: operationID, targetID: target.id)
                    return true
                } catch {
                    return false
                }
            }.value
            if !didRemoveRecord {
                journalIsClean = false
            }

            await recordTargetOutcome(
                ClaudeUpdateOutcome(
                    targetID: target.id,
                    host: target.host,
                    status: didRemoveRecord ? (desiredStatus ?? .restored) : .restored,
                    issue: didRemoveRecord ? operationIssue : .journalUnavailable,
                    versionBefore: versionBefore,
                    versionAfter: versionAfter
                ),
                operationID: operationID
            )
        }
        return (allSessionsVerified, journalIsClean)
    }

    private func transition(
        operationID: UUID,
        host: ClaudeUpdateHostIdentity,
        targetID: ClaudeUpdateTargetID,
        phase: ClaudeUpdatePhase
    ) async {
        guard activeOperationID == operationID, executionContext != nil else { return }
        executionContext?.transition(host: host, targetID: targetID, phase: phase)
        if let snapshot = executionContext?.snapshot {
            executionContext?.continuation.yield(snapshot)
        }
        await log(
            operationID: operationID,
            level: .info,
            phase: phase,
            host: host,
            targetID: targetID,
            issue: nil
        )
    }

    private func recordTargetOutcome(
        _ outcome: ClaudeUpdateOutcome,
        operationID: UUID
    ) async {
        guard activeOperationID == operationID, executionContext != nil else { return }
        executionContext?.record(outcome)
        if let snapshot = executionContext?.snapshot {
            executionContext?.continuation.yield(snapshot)
        }
        let level: ClaudeUpdateLogLevel = outcome.status == .failed
            ? .error
            : (outcome.status == .skipped || outcome.status == .restored ? .warning : .info)
        await log(
            operationID: operationID,
            level: level,
            phase: .completed,
            host: outcome.host,
            targetID: outcome.targetID,
            issue: outcome.issue
        )
    }

    private func recordHostOutcome(
        _ outcome: ClaudeUpdateHostOutcome,
        operationID: UUID
    ) async {
        guard activeOperationID == operationID, executionContext != nil else { return }
        executionContext?.record(outcome)
        if let snapshot = executionContext?.snapshot {
            executionContext?.continuation.yield(snapshot)
        }
        let level: ClaudeUpdateLogLevel = outcome.status == .failed
            ? .error
            : (outcome.status == .skipped || outcome.status == .restored ? .warning : .info)
        await log(
            operationID: operationID,
            level: level,
            phase: .completed,
            host: outcome.host,
            targetID: nil,
            issue: outcome.issue
        )
    }

    private func recordUnfinishedTargets(
        in targets: [ClaudeUpdateTarget],
        status: ClaudeUpdateOutcomeStatus,
        issue: ClaudeUpdateIssue,
        versionBefore: ClaudeVersion? = nil,
        versionAfter: ClaudeVersion? = nil
    ) async {
        guard let operationID = activeOperationID else { return }
        for target in targets where !hasOutcome(for: target.id) {
            await recordTargetOutcome(
                ClaudeUpdateOutcome(
                    targetID: target.id,
                    host: target.host,
                    status: status,
                    issue: issue,
                    versionBefore: versionBefore,
                    versionAfter: versionAfter
                ),
                operationID: operationID
            )
        }
    }

    private func markCancellation() async {
        guard executionContext != nil else { return }
        executionContext?.cancellationRequested = true
        if let snapshot = executionContext?.snapshot {
            executionContext?.continuation.yield(snapshot)
        }
    }

    private func hasOutcome(for targetID: ClaudeUpdateTargetID) -> Bool {
        executionContext?.outcomes.contains(where: { $0.targetID == targetID }) ?? false
    }

    private func hasUsableBinding(_ target: ClaudeUpdateTarget) -> Bool {
        guard let binding = target.binding else { return false }
        return binding.workingDirectory.hasPrefix("/")
            && binding.executablePath.hasPrefix("/")
            && !binding.installationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasValidShape(_ target: ClaudeUpdateTarget) -> Bool {
        switch target.host.kind {
        case .local:
            return target.pane == nil
        case .remote:
            guard let pane = target.pane else { return false }
            return !pane.sessionName.isEmpty && !pane.paneID.isEmpty
        }
    }

    private func log(
        operationID: UUID,
        level: ClaudeUpdateLogLevel,
        phase: ClaudeUpdatePhase,
        host: ClaudeUpdateHostIdentity?,
        targetID: ClaudeUpdateTargetID?,
        issue: ClaudeUpdateIssue?
    ) async {
        let timestamp = await clock.now()
        await logger.record(
            ClaudeUpdateLogEntry(
                timestamp: timestamp,
                operationID: operationID,
                level: level,
                phase: phase,
                hostID: host?.id,
                targetID: targetID,
                issue: issue
            )
        )
    }
}
