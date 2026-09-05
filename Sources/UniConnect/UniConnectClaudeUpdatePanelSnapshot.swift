import Foundation

/// Immutable application-state projection for one visible terminal panel.
struct UniConnectClaudeUpdatePanelSnapshot: Sendable {
    let id: UUID
    let workspaceID: UUID
    /// Runtime identity that changes when this stable panel ID is rebound during respawn.
    let surfaceGeneration: UUID?
    let displayName: String
    let directory: String?
    let persistedClaudeSessionID: String?
    let tmuxSession: String?
    let isDisconnected: Bool
    let lifecycle: String?
    let shellActivity: String?
    let restorableAgent: SessionRestorableAgentSnapshot?
}
