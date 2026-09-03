/// Receives structured state-machine events without raw process or credential text.
public protocol ClaudeUpdateLogging: Sendable {
    /// Persists or forwards one structured updater event.
    ///
    /// Logging is observational and must not throw or block session recovery.
    ///
    /// - Parameter entry: The credential-free event to record.
    func record(_ entry: ClaudeUpdateLogEntry) async
}
