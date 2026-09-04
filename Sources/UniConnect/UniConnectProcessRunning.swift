import Foundation

/// Runs one shell-free subprocess with bounded input, output, deadline, and cancellation.
protocol UniConnectProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: Duration
    ) async throws -> UniConnectProcessResult
}
