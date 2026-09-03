/// The terminal result of one host-level update command and all restoration obligations.
public struct ClaudeUpdateHostOutcome: Sendable, Hashable, Codable, Identifiable {
    /// The host and stable collection identifier.
    public let host: ClaudeUpdateHostIdentity

    /// The host-level terminal disposition.
    public let status: ClaudeUpdateOutcomeStatus

    /// A credential-free reason for non-success or restoration-only outcomes.
    public let issue: ClaudeUpdateIssue?

    /// The installed version captured before sessions exited.
    public let versionBefore: ClaudeVersion?

    /// The installed version captured after the command.
    public let versionAfter: ClaudeVersion?

    /// Captured sanitized output, or `nil` when no update command ran.
    public let command: ClaudeUpdateCommandResult?

    /// The stable host identity used by collection views.
    public var id: ClaudeUpdateHostIdentity { host }

    /// Creates a host outcome.
    ///
    /// - Parameters:
    ///   - host: The grouped host identity.
    ///   - status: The terminal disposition.
    ///   - issue: A credential-free reason code, when relevant.
    ///   - versionBefore: The pre-update version.
    ///   - versionAfter: The post-update version.
    ///   - command: Sanitized captured update command output.
    public init(
        host: ClaudeUpdateHostIdentity,
        status: ClaudeUpdateOutcomeStatus,
        issue: ClaudeUpdateIssue? = nil,
        versionBefore: ClaudeVersion? = nil,
        versionAfter: ClaudeVersion? = nil,
        command: ClaudeUpdateCommandResult? = nil
    ) {
        self.host = host
        self.status = status
        self.issue = issue
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
        self.command = command
    }
}
