/// A pure assessment of one installation-level update attempt.
public struct ClaudeBinaryUpdateAssessment: Sendable, Hashable, Codable {
    /// The proven binary disposition.
    public let status: ClaudeBinaryUpdateStatus

    /// A reason code when the disposition is ``ClaudeBinaryUpdateStatus/failed``.
    public let issue: ClaudeUpdateIssue?

    /// Creates a binary update assessment.
    ///
    /// - Parameters:
    ///   - status: The proven update disposition.
    ///   - issue: The credential-free failure reason, if any.
    public init(status: ClaudeBinaryUpdateStatus, issue: ClaudeUpdateIssue? = nil) {
        self.status = status
        self.issue = issue
    }
}
