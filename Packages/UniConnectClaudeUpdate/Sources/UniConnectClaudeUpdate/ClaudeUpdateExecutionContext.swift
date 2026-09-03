import Foundation

/// Actor-confined mutable projection used to emit immutable progress snapshots.
struct ClaudeUpdateExecutionContext {
    let plan: ClaudeUpdatePlan
    let startedAt: Date
    let continuation: AsyncStream<ClaudeUpdateProgress>.Continuation
    var phase: ClaudeUpdatePhase
    var currentHost: ClaudeUpdateHostIdentity?
    var currentTargetID: ClaudeUpdateTargetID?
    var targetPhases: [ClaudeUpdateTargetID: ClaudeUpdatePhase]
    var outcomes: [ClaudeUpdateOutcome]
    var hostOutcomes: [ClaudeUpdateHostOutcome]
    var cancellationRequested: Bool

    init(
        plan: ClaudeUpdatePlan,
        startedAt: Date,
        continuation: AsyncStream<ClaudeUpdateProgress>.Continuation
    ) {
        self.plan = plan
        self.startedAt = startedAt
        self.continuation = continuation
        self.phase = .preflight
        self.currentHost = nil
        self.currentTargetID = nil
        self.targetPhases = Dictionary(
            uniqueKeysWithValues: plan.targets.map { ($0.id, ClaudeUpdatePhase.pending) }
        )
        self.outcomes = []
        self.hostOutcomes = []
        self.cancellationRequested = false
    }

    var snapshot: ClaudeUpdateProgress {
        ClaudeUpdateProgress(
            operationID: plan.id,
            scope: plan.scope,
            phase: phase,
            currentHost: currentHost,
            currentTargetID: currentTargetID,
            targetPhases: targetPhases,
            outcomes: outcomes,
            hostOutcomes: hostOutcomes,
            isCancellationRequested: cancellationRequested
        )
    }

    mutating func transition(
        host: ClaudeUpdateHostIdentity?,
        targetID: ClaudeUpdateTargetID?,
        phase: ClaudeUpdatePhase
    ) {
        self.phase = phase
        self.currentHost = host
        self.currentTargetID = targetID
        if let targetID {
            targetPhases[targetID] = phase
        }
    }

    mutating func record(_ outcome: ClaudeUpdateOutcome) {
        guard !outcomes.contains(where: { $0.targetID == outcome.targetID }) else { return }
        outcomes.append(outcome)
        targetPhases[outcome.targetID] = .completed
    }

    mutating func record(_ outcome: ClaudeUpdateHostOutcome) {
        guard !hostOutcomes.contains(where: { $0.host == outcome.host }) else { return }
        hostOutcomes.append(outcome)
    }
}
