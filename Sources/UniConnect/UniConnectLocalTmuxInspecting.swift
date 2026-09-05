import Foundation

/// Verifies the live pane behind a saved binding before trusting its pre-reattach hook generation.
protocol UniConnectLocalTmuxInspecting: Sendable {
    func generation(
        for binding: UniConnectLocalTmuxBinding,
        workspaceID: UUID,
        panelID: UUID
    ) async -> UUID?
}
