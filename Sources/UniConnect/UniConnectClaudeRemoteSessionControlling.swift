import UniConnectClaudeUpdate

/// Controls exact SSH/tmux Claude sessions through bounded out-of-band commands.
protocol UniConnectClaudeRemoteSessionControlling: Sendable {
    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection

    func requestCleanExit(
        _ target: ClaudeUpdateTarget,
        expectedProcessID: Int32
    ) async throws

    func waitForShellAfterExit(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws

    func restore(_ target: ClaudeUpdateTarget, replacingProcessID: Int32?) async throws
}
