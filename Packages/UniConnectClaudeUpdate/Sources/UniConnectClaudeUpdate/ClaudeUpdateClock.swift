import Foundation

/// Supplies deterministic timestamps without coupling orchestration to the system clock.
public protocol ClaudeUpdateClock: Sendable {
    /// Returns the current timestamp.
    ///
    /// - Returns: The current time for progress, logs, journals, and summaries.
    func now() async -> Date
}
