/// The terminal result for one visible Claude session target.
public struct ClaudeUpdateOutcome: Sendable, Hashable, Codable, Identifiable {
    /// The target and stable collection identifier.
    public let targetID: ClaudeUpdateTargetID

    /// The target's host identity.
    public let host: ClaudeUpdateHostIdentity

    /// The terminal disposition.
    public let status: ClaudeUpdateOutcomeStatus

    /// A credential-free reason for non-success or restoration-only outcomes.
    public let issue: ClaudeUpdateIssue?

    /// The host version captured before sessions exited.
    public let versionBefore: ClaudeVersion?

    /// The host version captured after the update attempt.
    public let versionAfter: ClaudeVersion?

    /// The stable target identifier used by collection views.
    public var id: ClaudeUpdateTargetID { targetID }

    /// Creates a target outcome.
    ///
    /// - Parameters:
    ///   - targetID: The visible target identifier.
    ///   - host: The target's host.
    ///   - status: The terminal disposition.
    ///   - issue: A credential-free reason code, when relevant.
    ///   - versionBefore: The captured version before exit.
    ///   - versionAfter: The captured version after update.
    public init(
        targetID: ClaudeUpdateTargetID,
        host: ClaudeUpdateHostIdentity,
        status: ClaudeUpdateOutcomeStatus,
        issue: ClaudeUpdateIssue? = nil,
        versionBefore: ClaudeVersion? = nil,
        versionAfter: ClaudeVersion? = nil
    ) {
        self.targetID = targetID
        self.host = host
        self.status = status
        self.issue = issue
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
    }
}
