import Foundation

/// Executes one bounded SSH maintenance request outside an interactive terminal.
protocol UniConnectSSHCommandExecuting: Sendable {
    func execute(
        _ invocation: UniConnectSSHProcessInvocation,
        timeout: Duration
    ) async throws
}
