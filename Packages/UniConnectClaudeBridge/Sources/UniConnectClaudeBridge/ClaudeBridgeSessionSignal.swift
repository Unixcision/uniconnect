import Foundation

/// Immutable authenticated session metadata emitted for updater coordination.
///
/// The signal intentionally excludes prompts, responses, transcripts, credentials,
/// SSH commands, and executable paths.
public struct ClaudeBridgeSessionSignal: Sendable, Equatable {
    /// Trusted local route that accepted the authenticated event.
    public let routeID: UUID

    /// Claude session UUID or bounded non-resumable correlation identifier.
    public let sessionID: String

    /// Validated remote absolute working directory.
    public let cwd: String

    /// Validated concrete tmux pane identifier.
    public let tmuxPane: String

    /// Official Claude lifecycle event that produced the signal.
    public let kind: ClaudeBridgeEventKind

    /// Freshness-validated event time.
    public let occurredAt: Date

    /// Creates a privacy-minimized updater signal from an authenticated event.
    ///
    /// - Parameters:
    ///   - routeID: Trusted local route UUID.
    ///   - sessionID: Claude UUID or correlation identifier.
    ///   - cwd: Validated remote absolute working directory.
    ///   - tmuxPane: Validated concrete tmux pane identifier.
    ///   - kind: Official lifecycle event kind.
    ///   - occurredAt: Freshness-validated event time.
    public init(
        routeID: UUID,
        sessionID: String,
        cwd: String,
        tmuxPane: String,
        kind: ClaudeBridgeEventKind,
        occurredAt: Date
    ) {
        self.routeID = routeID
        self.sessionID = sessionID
        self.cwd = cwd
        self.tmuxPane = tmuxPane
        self.kind = kind
        self.occurredAt = occurredAt
    }
}
