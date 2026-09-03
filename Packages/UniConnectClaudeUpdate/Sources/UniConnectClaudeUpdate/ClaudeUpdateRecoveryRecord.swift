import Foundation

/// A durable instruction to reconcile and restore one exact Claude session.
public struct ClaudeUpdateRecoveryRecord: Sendable, Hashable, Codable, Identifiable {
    /// The update operation that armed recovery.
    public let operationID: UUID

    /// The complete non-credential target snapshot needed for recovery.
    public let target: ClaudeUpdateTarget

    /// The latest durable recovery stage.
    public let stage: ClaudeRecoveryStage

    /// The exact Claude PID observed immediately before the clean exit request.
    public let observedProcessID: Int32

    /// The version captured before any exit request on this host.
    public let versionBefore: ClaudeVersion?

    /// The time at which this record was last written.
    public let updatedAt: Date

    /// A stable journal key combining operation and target identity.
    public var id: String { "\(operationID.uuidString):\(target.id.rawValue)" }

    /// Creates a durable recovery record.
    ///
    /// - Parameters:
    ///   - operationID: The update operation that armed recovery.
    ///   - target: The exact target snapshot to reconcile.
    ///   - stage: The latest durable stage.
    ///   - observedProcessID: The exact Claude PID observed before exit.
    ///   - versionBefore: The version captured before exit.
    ///   - updatedAt: The timestamp supplied by the injected clock.
    public init(
        operationID: UUID,
        target: ClaudeUpdateTarget,
        stage: ClaudeRecoveryStage,
        observedProcessID: Int32,
        versionBefore: ClaudeVersion?,
        updatedAt: Date
    ) {
        self.operationID = operationID
        self.target = target
        self.stage = stage
        self.observedProcessID = observedProcessID
        self.versionBefore = versionBefore
        self.updatedAt = updatedAt
    }
}
