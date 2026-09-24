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

    /// How this agent is closed. ``RelaunchClosing/sequenced`` unless the adapter says otherwise.
    var closing: RelaunchClosing { get }

    /// Why the pane may not be closed right now, read together with its cursor; `nil` means it may.
    ///
    /// Only asked by ``RelaunchClosing/confirmedCommand(_:)`` adapters, before anything is typed and
    /// again to recognise the agent back at its prompt after reopening.
    func refusalToClose(screen: RelaunchPaneScreen) -> RelaunchCause?

    /// Whether the close command sits typed on the cursor line, ready for return.
    func showsCloseCommand(screen: RelaunchPaneScreen) -> Bool

    /// Whether a live process's argv (as `ps` gives it) is on `conversation`.
    func resumes(conversation: String, argv: [String]) -> Bool
}

extension RelaunchAgentDialect {
    /// Claude and every adapter that does not say otherwise are walked out step by step.
    public var closing: RelaunchClosing { .sequenced }

    /// No cursor-based refusal unless the adapter defines one.
    public func refusalToClose(screen: RelaunchPaneScreen) -> RelaunchCause? { nil }

    /// Only adapters that confirm their close command recognise it on screen.
    public func showsCloseCommand(screen: RelaunchPaneScreen) -> Bool { false }

    /// The value attached to `--resume`/`-r` (or `--resume=`), and only that, names the conversation.
    public func resumes(conversation: String, argv: [String]) -> Bool {
        var index = argv.startIndex
        while index < argv.endIndex {
            let argument = argv[index]
            if argument == "--resume" || argument == "-r" {
                let value = argv.index(after: index)
                return value < argv.endIndex && argv[value] == conversation
            }
            if argument.hasPrefix("--resume=") {
                return String(argument.dropFirst("--resume=".count)) == conversation
            }
            index = argv.index(after: index)
        }
        return false
    }

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
    ///
    /// Claude, on local windows (`contracts/relaunch-v1/proveedores.json`). ``CodexRelaunchDialect``
    /// is written but stays out until a live test: relaunching closes the agent, and its identity
    /// (the open rollout versus the saved one) and the npm launcher next to the native binary have
    /// never been exercised on a real Codex.
    public static let known = RelaunchDialects([ClaudeRelaunchDialect()])

    /// The adapter for `provider`, or `nil` when this build does not know that agent's life cycle.
    public func dialect(for provider: String) -> (any RelaunchAgentDialect)? {
        byProvider[provider.lowercased()]
    }

    public var supportedProviders: Set<String> { Set(byProvider.keys) }

    /// The capability tokens that announce these adapters for one kind of window.
    ///
    /// One `relaunch.v1.<proveedor>.<tipo>` per provider, sorted, as `contracts/relaunch-v1/
    /// proveedores.json` fixes them: the Mac announces `.local` only, because its SSH windows stay
    /// `no_soportado`.
    ///
    /// - Parameter kind: `local` or `ssh`.
    /// - Returns: For example `["relaunch.v1.claude.local", "relaunch.v1.codex.local"]`.
    public func capabilityTokens(windowKind kind: String) -> [String] {
        supportedProviders.sorted().map { "relaunch.v1.\($0).\(kind)" }
    }
}
