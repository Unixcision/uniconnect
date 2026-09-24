import Foundation

/// Verifies the live pane behind a saved binding before trusting its pre-reattach hook generation.
protocol UniConnectLocalTmuxInspecting: Sendable {
    /// Missing or ambiguous evidence yields no observation and must preserve durable state.
    func runtimeObservations(
        for targets: [UniConnectLocalTmuxRuntimeObservation.Target]
    ) async -> [UniConnectLocalTmuxRuntimeObservation]

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

    /// Reads the live `$N`/`%N` of an existing session, read-only; `nil` when it is not running.
    func liveIdentity(binding: UniConnectLocalTmuxBinding) async -> UniConnectLocalTmuxLiveIdentity?

    /// Whether the tmux server of `socketName` answers, read-only (it never starts one).
    ///
    /// `false` only when tmux says there is no server (`no server running`, `error connecting`,
    /// `No such file`); `nil` when it could not be told.
    func serverIsRunning(socketName: String) async -> Bool?
}

extension UniConnectLocalTmuxInspecting {
    /// Inspectors that cannot tell leave interruptions unmarked.
    func serverIsRunning(socketName: String) async -> Bool? { nil }
}
