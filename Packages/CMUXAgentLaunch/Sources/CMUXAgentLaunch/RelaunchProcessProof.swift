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

    /// Whether the caller already established that the process was replaced.
    ///
    /// Nil when the answer has to be read off ``before`` and ``after``, which is the older and
    /// weaker way to ask: two identifiers can match while the processes differ, because the kernel
    /// reuses them. A caller that can compare full identities — identifier *and* start time —
    /// answers this directly and is believed.
    private let settled: Bool?

    public init(before: Int32, after: Int32?) {
        self.before = before
        self.after = after
        self.settled = nil
    }

    /// Creates a proof from an answer the caller already established by comparing identities.
    ///
    /// Preferred over the identifier form wherever the caller knows more than a number: a pane's
    /// agent is identified by its process **and** its start time, and reducing that pair to one
    /// integer can only lose information — a hash can collide into a false "not replaced", and a
    /// reused identifier reads as a false "same process".
    ///
    /// - Parameters:
    ///   - replacedProcess: Whether a genuinely different process is now in place.
    ///   - before: The identifier of the process that was there, kept for reporting.
    ///   - after: The identifier now in place, or nil when nothing is.
    public init(replacedProcess: Bool, before: Int32, after: Int32?) {
        self.before = before
        self.after = after
        self.settled = replacedProcess
    }

    /// Whether a new agent is demonstrably in place.
    public var provesNewProcess: Bool {
        guard after != nil else { return false }
        if let settled { return settled }
        return after != before
    }

    /// Why this does not prove a relaunch, when it does not.
    public var failureCause: RelaunchCause? {
        guard after != nil else { return .unknownDialog }
        return provesNewProcess ? nil : .ambiguousIdentity
    }
}
