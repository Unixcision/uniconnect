/// Resolves one SSH/tmux panel to exact updater identities without sending terminal input.
protocol UniConnectClaudeRemoteTargetResolving: Sendable {
    func resolve(
        workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        panel: UniConnectClaudeUpdatePanelSnapshot
    ) async -> UniConnectClaudeRemoteTargetResolution?
}
