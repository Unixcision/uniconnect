/// One visible terminal whose Claude session may be stopped, updated, and restored.
public struct ClaudeUpdateTarget: Sendable, Hashable, Codable, Identifiable {
    /// The stable visible-target identifier.
    public let id: ClaudeUpdateTargetID

    /// The UniConnect box containing the target.
    public let boxID: String

    /// A presentation-only target name.
    public let displayName: String

    /// The host on which the Claude process and executable live.
    public let host: ClaudeUpdateHostIdentity

    /// The persisted restore binding, or `nil` when identity resolution was unsafe.
    public let binding: ClaudeSessionBinding?

    /// The exact remote pane, or `nil` for local and unresolved remote targets.
    public let pane: ClaudeTmuxPaneIdentity?

    /// Creates an immutable Claude update target.
    ///
    /// Keeping unresolved binding or pane values as `nil` lets a broad operation safely skip one
    /// ambiguous target without preventing unrelated, fully identified targets from updating.
    ///
    /// - Parameters:
    ///   - id: The stable visible-target identifier.
    ///   - boxID: The owning UniConnect box identifier.
    ///   - displayName: A non-secret presentation name.
    ///   - host: The target host.
    ///   - binding: The exact persisted session binding, when safely known.
    ///   - pane: The exact tmux pane for a remote target, when safely known.
    public init(
        id: ClaudeUpdateTargetID,
        boxID: String,
        displayName: String,
        host: ClaudeUpdateHostIdentity,
        binding: ClaudeSessionBinding?,
        pane: ClaudeTmuxPaneIdentity?
    ) {
        self.id = id
        self.boxID = boxID
        self.displayName = displayName
        self.host = host
        self.binding = binding
        self.pane = pane
    }
}
