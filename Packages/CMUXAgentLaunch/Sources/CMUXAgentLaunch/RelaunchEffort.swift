import Foundation

/// The reasoning effort a Claude can be reopened with (`--effort`), as `agent.update` accepts it.
///
/// A closed list on purpose: the value is typed into a shell and into Claude's own command line,
/// so anything not on it is refused with ``RelaunchError/invalidOptions`` instead of passed along.
public enum RelaunchEffort: String, Sendable, Codable, CaseIterable {
    /// `--effort low`.
    case low
    /// `--effort medium`.
    case medium
    /// `--effort high`.
    case high
    /// `--effort xhigh`.
    case xhigh
    /// `--effort max`.
    case max
}
