import UniConnectClaudeUpdate

/// Exact remote binding and pane identity discovered without mutating the tmux session.
struct UniConnectClaudeRemoteTargetResolution: Sendable, Equatable {
    let binding: ClaudeSessionBinding
    let pane: ClaudeTmuxPaneIdentity
}
