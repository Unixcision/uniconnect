/// Whether a Claude installation runs on this Mac or behind an SSH connection.
public enum ClaudeUpdateHostKind: String, Sendable, Hashable, Codable {
    /// The local Mac running UniConnect.
    case local

    /// A remote host reached through an application-owned SSH credential and endpoint.
    case remote
}
