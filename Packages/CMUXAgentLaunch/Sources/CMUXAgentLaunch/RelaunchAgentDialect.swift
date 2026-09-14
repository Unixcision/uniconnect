import Foundation

/// Everything needed to close one kind of agent and bring the same conversation back.
///
/// A screen reader is not enough, and believing otherwise is the quickest way to ruin somebody's
/// conversation. An adapter has to supply three things a reader cannot:
///
/// - **Identity from outside the screen.** Claude prints its conversation on the way out; Codex does
///   not, and there it is settled by a writer lock the live process actually holds.
/// - **The invocation as arguments**, not as a sentence. A joined string invites a quoting mistake
///   to become an argument, and these lines carry flags that decide what an agent may do.
/// - **Proof that a new process is in place.** A pane that looks the same can be a pane where
///   nothing happened.
///
/// An agent without an adapter is reported as ``RelaunchCause/unsupported`` and left untouched.
/// Knowing how an agent is *spelled* is not knowing its life cycle.
public protocol RelaunchAgentDialect: Sendable {
    /// The provider this adapter speaks for, as the host names it (`claude`, `codex`, …).
    var provider: String { get }

    /// Reads what a pane is showing.
    ///
    /// Anything not positively recognised is ``RelaunchScreenReading/unrecognised``. There is no
    /// universal list of safe texts: an unfamiliar permission, trust prompt, folder chooser or a
    /// draft somebody left half-typed all end the attempt rather than get answered.
    func read(screen: String) -> RelaunchScreenReading

    /// The conversation `evidence` proves this pane is on, or `nil` when it proves none.
    func conversation(from evidence: RelaunchIdentityEvidence) -> String?

    /// The argv that brings `conversation` back, preserving `previousArgv`'s flags.
    ///
    /// Returns `nil` when this adapter cannot be sure, which is a refusal and not a fallback.
    func invocation(conversation: String, previousArgv: [String]) -> [String]?

    /// Whether the pane ended up holding a genuinely relaunched agent.
    func verify(proof: RelaunchProcessProof, reading: RelaunchScreenReading) -> Result<Void, RelaunchCause>
}

extension RelaunchAgentDialect {
    /// The default verification every adapter gets: a new process, and an agent at its prompt.
    public func verify(
        proof: RelaunchProcessProof,
        reading: RelaunchScreenReading
    ) -> Result<Void, RelaunchCause> {
        if let cause = proof.failureCause { return .failure(cause) }
        return reading == .agentReady ? .success(()) : .failure(.unknownDialog)
    }
}

/// Picks the adapter for a provider, and refuses when there is none.
public struct RelaunchDialects: Sendable {
    private let byProvider: [String: any RelaunchAgentDialect]

    public init(_ dialects: [any RelaunchAgentDialect]) {
        byProvider = Dictionary(uniqueKeysWithValues: dialects.map { ($0.provider, $0) })
    }

    /// Every agent this build knows how to relaunch **and verify**, which is a shorter list than the
    /// agents it knows how to launch.
    public static let known = RelaunchDialects([ClaudeRelaunchDialect()])

    /// The adapter for `provider`, or `nil` when this build does not know that agent's life cycle.
    public func dialect(for provider: String) -> (any RelaunchAgentDialect)? {
        byProvider[provider.lowercased()]
    }

    public var supportedProviders: Set<String> { Set(byProvider.keys) }
}
