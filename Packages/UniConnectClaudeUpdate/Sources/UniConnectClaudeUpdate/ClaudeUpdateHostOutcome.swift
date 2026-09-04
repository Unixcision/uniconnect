/// The terminal result of one installation-level update command and all restoration obligations.
public struct ClaudeUpdateHostOutcome: Sendable, Hashable, Codable, Identifiable {
    /// The host and stable collection identifier.
    public let host: ClaudeUpdateHostIdentity

    /// The non-secret installation identity updated on the host, when resolved.
    public let installationID: String?

    /// The installation-level terminal disposition.
    public let status: ClaudeUpdateOutcomeStatus

    /// A credential-free reason for non-success or restoration-only outcomes.
    public let issue: ClaudeUpdateIssue?

    /// The installed version captured before sessions exited.
    public let versionBefore: ClaudeVersion?

    /// The installed version captured after the command.
    public let versionAfter: ClaudeVersion?

    /// Captured sanitized output, or `nil` when no update command ran.
    public let command: ClaudeUpdateCommandResult?

    /// The stable host-and-installation identity used by collection views.
    public var id: ClaudeUpdateHostPlanID {
        ClaudeUpdateHostPlanID(host: host, installationID: installationID)
    }

    /// Creates a host outcome.
    ///
    /// - Parameters:
    ///   - host: The grouped host identity.
    ///   - installationID: The non-secret installation identity, when resolved.
    ///   - status: The terminal disposition.
    ///   - issue: A credential-free reason code, when relevant.
    ///   - versionBefore: The pre-update version.
    ///   - versionAfter: The post-update version.
    ///   - command: Sanitized captured update command output.
    public init(
        host: ClaudeUpdateHostIdentity,
        installationID: String? = nil,
        status: ClaudeUpdateOutcomeStatus,
        issue: ClaudeUpdateIssue? = nil,
        versionBefore: ClaudeVersion? = nil,
        versionAfter: ClaudeVersion? = nil,
        command: ClaudeUpdateCommandResult? = nil
    ) {
        self.host = host
        self.installationID = installationID
        self.status = status
        self.issue = issue
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
        self.command = command
    }
}
