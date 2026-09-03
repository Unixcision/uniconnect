import Foundation

/// A running update operation with an immutable progress stream and cancellable result task.
public struct ClaudeUpdateOperation: Sendable, Identifiable {
    /// The operation identifier shared by progress, summary, logs, and recovery records.
    public let id: UUID

    /// Buffered immutable progress snapshots, finished when the result becomes available.
    public let progress: AsyncStream<ClaudeUpdateProgress>

    private let resultTask: Task<ClaudeUpdateSummary, Never>

    init(
        id: UUID,
        progress: AsyncStream<ClaudeUpdateProgress>,
        resultTask: Task<ClaudeUpdateSummary, Never>
    ) {
        self.id = id
        self.progress = progress
        self.resultTask = resultTask
    }

    /// Requests cooperative cancellation.
    ///
    /// Cancellation prevents new exits and updates. Any target already durably armed for recovery
    /// is still restored and verified before ``result()`` completes.
    public func cancel() {
        resultTask.cancel()
    }

    /// Awaits the final summary, including cancellation-triggered restoration outcomes.
    ///
    /// - Returns: The operation's immutable terminal summary.
    public func result() async -> ClaudeUpdateSummary {
        await resultTask.value
    }
}
