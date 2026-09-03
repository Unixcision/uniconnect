/// The user-visible terminal disposition of a host or session target.
public enum ClaudeUpdateOutcomeStatus: String, Sendable, Hashable, Codable {
    /// The installed version increased and the session was restored.
    case updated

    /// The installed version was already current and the session was restored.
    case alreadyUpdated

    /// The update did not complete, but the prior session was safely restored.
    case restored

    /// No destructive action was taken for this host or target.
    case skipped

    /// Safety, update, restoration, or verification failed.
    case failed
}
