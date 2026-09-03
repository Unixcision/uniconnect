/// The durable stage of an outstanding session-restoration obligation.
public enum ClaudeRecoveryStage: String, Sendable, Hashable, Codable {
    /// Recovery was persisted before the clean exit request was sent.
    case exitRequested

    /// The old Claude process was confirmed gone and the terminal returned to its shell.
    case shellReady

    /// A cancellation-resistant restoration attempt has started.
    case restorationStarted
}
