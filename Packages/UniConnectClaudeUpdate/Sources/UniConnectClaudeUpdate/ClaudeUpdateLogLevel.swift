/// The severity of a structured, credential-free updater log entry.
public enum ClaudeUpdateLogLevel: String, Sendable, Hashable, Codable {
    /// Normal state-machine progress.
    case info

    /// A skipped target or recoverable degradation.
    case warning

    /// A failed safety, update, or restoration operation.
    case error
}
