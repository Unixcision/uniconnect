import Foundation

/// An immutable snapshot suitable for direct projection into update UI.
public struct ClaudeUpdateProgress: Sendable, Equatable {
    /// The operation identifier.
    public let operationID: UUID

    /// The requested selection scope.
    public let scope: ClaudeUpdateScope

    /// The current operation-level phase.
    public let phase: ClaudeUpdatePhase

    /// The host currently being processed, if any.
    public let currentHost: ClaudeUpdateHostIdentity?

    /// The target currently being processed, if any.
    public let currentTargetID: ClaudeUpdateTargetID?

    /// A phase snapshot for every target in the plan.
    public let targetPhases: [ClaudeUpdateTargetID: ClaudeUpdatePhase]

    /// Completed target outcomes in deterministic completion order.
    public let outcomes: [ClaudeUpdateOutcome]

    /// Completed host-and-installation outcomes in deterministic plan order.
    public let hostOutcomes: [ClaudeUpdateHostOutcome]

    /// Whether cancellation was observed and no new mutation will start.
    public let isCancellationRequested: Bool

    /// Creates an immutable progress snapshot.
    ///
    /// - Parameters:
    ///   - operationID: The operation identifier.
    ///   - scope: The requested selection scope.
    ///   - phase: The operation-level phase.
    ///   - currentHost: The host currently being processed.
    ///   - currentTargetID: The target currently being processed.
    ///   - targetPhases: Current per-target phases.
    ///   - outcomes: Completed target outcomes.
    ///   - hostOutcomes: Completed host-and-installation outcomes.
    ///   - isCancellationRequested: Whether cancellation has been observed.
    public init(
        operationID: UUID,
        scope: ClaudeUpdateScope,
        phase: ClaudeUpdatePhase,
        currentHost: ClaudeUpdateHostIdentity?,
        currentTargetID: ClaudeUpdateTargetID?,
        targetPhases: [ClaudeUpdateTargetID: ClaudeUpdatePhase],
        outcomes: [ClaudeUpdateOutcome],
        hostOutcomes: [ClaudeUpdateHostOutcome],
        isCancellationRequested: Bool
    ) {
        self.operationID = operationID
        self.scope = scope
        self.phase = phase
        self.currentHost = currentHost
        self.currentTargetID = currentTargetID
        self.targetPhases = targetPhases
        self.outcomes = outcomes
        self.hostOutcomes = hostOutcomes
        self.isCancellationRequested = isCancellationRequested
    }
}
