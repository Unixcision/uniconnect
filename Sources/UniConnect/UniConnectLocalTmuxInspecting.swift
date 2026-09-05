import Foundation

/// Verifies the live pane behind a saved binding before trusting its pre-reattach hook generation.
protocol UniConnectLocalTmuxInspecting: Sendable {
    func generation(
        for binding: UniConnectLocalTmuxBinding,
        workspaceID: UUID,
        panelID: UUID
    ) async -> UUID?

    /// Verifies that the kernel-observed peer belongs to a pane still owned by one supplied window.
    func verifiedOwner(
        of peer: UniConnectLocalTmuxProcessIdentity,
        among owners: [UniConnectLocalTmuxOwner]
    ) async -> UniConnectLocalTmuxOwner?
}
