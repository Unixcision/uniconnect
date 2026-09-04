import Foundation

/// Immutable application-state projection for one open UniConnect box.
struct UniConnectClaudeUpdateWorkspaceSnapshot: Sendable {
    let id: UUID
    let boxID: String
    let displayName: String
    let kind: UniConnectWorkspaceKind
    let credentialID: UUID?
    let hostLabel: String?
    let panels: [UniConnectClaudeUpdatePanelSnapshot]
}
