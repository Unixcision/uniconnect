/// Supplies real terminal/hook transitions to the update session controller.
protocol UniConnectClaudeSessionSignalStreaming: Sendable {
    func signals() async -> AsyncStream<UniConnectClaudeSessionSignal>
}
