import Foundation

/// A structured updater event whose schema cannot carry raw commands or credentials.
public struct ClaudeUpdateLogEntry: Sendable, Hashable, Codable {
    /// The event timestamp supplied by the injected clock.
    public let timestamp: Date

    /// The update operation identifier.
    public let operationID: UUID

    /// The event severity.
    public let level: ClaudeUpdateLogLevel

    /// The state-machine phase associated with the event.
    public let phase: ClaudeUpdatePhase

    /// The stable, non-secret host ID, when applicable.
    public let hostID: String?

    /// The stable, non-secret target ID, when applicable.
    public let targetID: ClaudeUpdateTargetID?

    /// A credential-free issue code, when applicable.
    public let issue: ClaudeUpdateIssue?

    /// Creates a structured updater log entry.
    ///
    /// - Parameters:
    ///   - timestamp: The event time supplied by the injected clock.
    ///   - operationID: The update operation identifier.
    ///   - level: The event severity.
    ///   - phase: The associated state-machine phase.
    ///   - hostID: A stable non-secret host ID.
    ///   - targetID: A stable non-secret target ID.
    ///   - issue: A credential-free issue code.
    public init(
        timestamp: Date,
        operationID: UUID,
        level: ClaudeUpdateLogLevel,
        phase: ClaudeUpdatePhase,
        hostID: String?,
        targetID: ClaudeUpdateTargetID?,
        issue: ClaudeUpdateIssue?
    ) {
        self.timestamp = timestamp
        self.operationID = operationID
        self.level = level
        self.phase = phase
        self.hostID = hostID
        self.targetID = targetID
        self.issue = issue
    }
}
