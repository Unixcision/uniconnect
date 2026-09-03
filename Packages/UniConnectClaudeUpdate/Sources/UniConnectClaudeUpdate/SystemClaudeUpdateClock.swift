import Foundation

/// A stateless production clock backed by the system wall clock.
public struct SystemClaudeUpdateClock: ClaudeUpdateClock {
    /// Creates a system updater clock.
    public init() {}

    /// Returns the current system wall-clock time.
    ///
    /// - Returns: `Date.now` at the call boundary.
    public func now() async -> Date { Date.now }
}
