import Foundation

/// The immutable final result of an update operation.
public struct ClaudeUpdateSummary: Sendable, Hashable, Codable {
    /// The validated plan that was executed.
    public let plan: ClaudeUpdatePlan

    /// Per-target outcomes in deterministic completion order.
    public let outcomes: [ClaudeUpdateOutcome]

    /// Per-host outcomes in deterministic plan order.
    public let hostOutcomes: [ClaudeUpdateHostOutcome]

    /// The operation start time supplied by the injected clock.
    public let startedAt: Date

    /// The operation completion time supplied by the injected clock.
    public let finishedAt: Date

    /// Whether cancellation was observed during the operation.
    public let wasCancelled: Bool

    /// Creates a final update summary.
    ///
    /// - Parameters:
    ///   - plan: The validated plan that ran.
    ///   - outcomes: Per-target terminal outcomes.
    ///   - hostOutcomes: Per-host terminal outcomes.
    ///   - startedAt: The injected-clock start time.
    ///   - finishedAt: The injected-clock completion time.
    ///   - wasCancelled: Whether cancellation was observed.
    public init(
        plan: ClaudeUpdatePlan,
        outcomes: [ClaudeUpdateOutcome],
        hostOutcomes: [ClaudeUpdateHostOutcome],
        startedAt: Date,
        finishedAt: Date,
        wasCancelled: Bool
    ) {
        self.plan = plan
        self.outcomes = outcomes
        self.hostOutcomes = hostOutcomes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wasCancelled = wasCancelled
    }
}
