import Foundation

/// Provides immutable snapshots of the open UniConnect boxes on the main actor.
@MainActor
protocol UniConnectClaudeUpdateApplicationStateReading: Sendable {
    func workspaceSnapshots() -> [UniConnectClaudeUpdateWorkspaceSnapshot]

    func panelSnapshot(
        workspaceID: UUID,
        panelID: UUID
    ) -> UniConnectClaudeUpdatePanelSnapshot?
}
