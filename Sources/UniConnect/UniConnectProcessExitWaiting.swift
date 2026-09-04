import Foundation

/// Awaits a kernel process-exit event without periodic process polling.
protocol UniConnectProcessExitWaiting: Sendable {
    func waitForExit(processID: Int32, timeout: Duration) async throws
}
