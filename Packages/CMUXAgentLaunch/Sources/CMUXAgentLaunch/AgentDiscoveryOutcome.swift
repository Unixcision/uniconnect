import Foundation

/// What one pane's process subtree says about the agent running in it.
///
/// Only ``found(_:)`` may change what is stored. Every other outcome leaves the saved conversation
/// exactly as it was: an ambiguous pane is never resolved by guessing.
public enum AgentDiscoveryOutcome: Sendable, Equatable {
    /// No agent process under the pane's shell (`sin_ia`).
    case noAgent
    /// More than one independent agent under the pane (`identidad_ambigua`).
    case ambiguous
    /// One agent, but no conversation id yet (`sin_id`), such as a fresh Codex before its first turn.
    ///
    /// Carries the agent's root pid, its resolved folder and whether it runs as root, which the
    /// details view still shows.
    case unidentified(AgentObservedProvider, processID: Int, workingDirectory: String?, asRoot: Bool)
    /// One agent on one known conversation.
    case found(AgentObservedConversation)

    /// The contract's `cause` for this outcome, or `nil` when the agent was identified.
    public var reason: String? {
        switch self {
        case .noAgent: "sin_ia"
        case .ambiguous: "identidad_ambigua"
        case .unidentified: "sin_id"
        case .found: nil
        }
    }
}
