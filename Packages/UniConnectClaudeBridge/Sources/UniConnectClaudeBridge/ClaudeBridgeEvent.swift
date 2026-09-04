import Foundation

/// An authenticated, privacy-minimized completion event from remote Claude Code.
public struct ClaudeBridgeEvent: Sendable, Equatable {
    /// The replay-protected event identifier.
    public let id: String

    /// The remote timestamp after bounded clock-skew validation.
    public let occurredAt: Date

    /// The official Claude Code hook signal.
    public let kind: ClaudeBridgeEventKind

    /// Claude's session UUID or a bounded correlation identifier.
    public let sessionCorrelation: String

    /// The remote working directory, with no transcript or message content.
    public let cwd: String

    /// The concrete tmux pane that emitted the hook when available.
    public let tmuxPane: String?

    /// Creates an authenticated event value.
    ///
    /// - Parameters:
    ///   - id: Replay-protected event identifier.
    ///   - occurredAt: Validated remote event date.
    ///   - kind: Official Claude Code hook signal.
    ///   - sessionCorrelation: Session UUID or bounded correlation identifier.
    ///   - cwd: Remote absolute working directory.
    ///   - tmuxPane: Optional concrete tmux pane identifier.
    public init(
        id: String,
        occurredAt: Date,
        kind: ClaudeBridgeEventKind,
        sessionCorrelation: String,
        cwd: String,
        tmuxPane: String?
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.sessionCorrelation = sessionCorrelation
        self.cwd = cwd
        self.tmuxPane = tmuxPane
    }
}
