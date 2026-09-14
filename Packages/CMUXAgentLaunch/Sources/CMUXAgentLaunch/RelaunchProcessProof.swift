import Foundation

/// Proof that the agent in a pane was actually replaced, and not merely repainted.
///
/// "The footer says the agent is ready" is not proof of a relaunch: the pane can look identical
/// because nothing happened at all. What proves it is a **different live process** than the one that
/// was there before, which is also what catches a close that silently failed.
public struct RelaunchProcessProof: Sendable, Equatable {
    /// The process occupying the pane before the attempt.
    public let before: Int32
    /// The process occupying the pane afterwards, if any.
    public let after: Int32?

    public init(before: Int32, after: Int32?) {
        self.before = before
        self.after = after
    }

    /// Whether a new agent is demonstrably in place.
    public var provesNewProcess: Bool {
        guard let after else { return false }
        return after != before
    }

    /// Why this does not prove a relaunch, when it does not.
    public var failureCause: RelaunchCause? {
        guard let after else { return .unknownDialog }
        return after == before ? .ambiguousIdentity : nil
    }
}
