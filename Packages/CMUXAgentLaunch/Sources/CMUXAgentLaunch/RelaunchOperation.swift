import Foundation

/// An accepted relaunch, and how far each of its targets has got.
///
/// `apply` answers with one of these as soon as the work is accepted and does **not** wait for it to
/// finish: closing and reopening twenty-six agents is not something to hold a phone request open
/// for. The client follows along with `relaunch.status`.
public struct RelaunchOperation: Sendable, Equatable {
    /// Whether the operation as a whole is still going.
    public enum State: String, Sendable, Codable {
        case running = "en_curso"
        case finished = "terminada"
    }

    /// Where one target got to, and why if it stopped.
    public struct Result: Sendable, Equatable {
        public let key: RelaunchTargetKey
        public let state: RelaunchTargetState
        public let cause: RelaunchCause?
        /// The conversation proven live afterwards. Only verbs that reopen a conversation have one.
        public let effectiveID: String?
        /// The agent the target runs (`claude`, `codex`, …), so ``effectiveID`` is recorded as a
        /// conversation of that agent and never of a fixed one.
        public let provider: String?
        /// The last escalation step the close needed, when anything was closed.
        public var escalation: RelaunchEscalation?
        /// Names of launch options that did not come back (never their values).
        public var droppedOptions: [String] = []
        /// The Claude version the reopened agent runs, when it could be read.
        public var version: String?
        /// The model the reopened agent runs, when it is known.
        public var model: String?
        /// The effort the reopened agent runs with, when it is known.
        public var effort: String?
        /// How many background monitors and shells were saved before closing.
        public var backgroundSaved: Int?
        /// Whether the post-reopen message was typed and submitted.
        public var messageSent: Bool?
        /// Whether the saved draft was written back into the composer.
        public var draftRestored: Bool?

        /// Creates the result of one target.
        ///
        /// - Parameters:
        ///   - key: The target.
        ///   - state: Where it got to.
        ///   - cause: Why it stopped, if it did.
        ///   - effectiveID: The conversation proven live afterwards.
        ///   - provider: The target's agent.
        public init(
            key: RelaunchTargetKey,
            state: RelaunchTargetState,
            cause: RelaunchCause? = nil,
            effectiveID: String? = nil,
            provider: String? = nil
        ) {
            self.key = key
            self.state = state
            self.cause = cause
            self.effectiveID = effectiveID
            self.provider = provider
        }

        /// The result as it travels in an `apply`/`status` response, absent values left out.
        public var json: [String: Any] {
            var item: [String: Any] = ["key": key.text, "state": state.rawValue]
            if let cause { item["cause"] = cause.rawValue }
            if let effectiveID { item["effective_id"] = effectiveID }
            if let escalation { item["escalation"] = escalation.rawValue }
            if !droppedOptions.isEmpty { item["dropped_options"] = droppedOptions }
            if let version { item["version"] = version }
            if let model { item["model"] = model }
            if let effort { item["effort"] = effort }
            if let backgroundSaved { item["background_saved"] = backgroundSaved }
            if let messageSent { item["message_sent"] = messageSent }
            if let draftRestored { item["draft_restored"] = draftRestored }
            return item
        }

        /// A copy carrying another state and cause, keeping everything else.
        ///
        /// - Parameters:
        ///   - state: The new state.
        ///   - cause: The new cause.
        /// - Returns: The same result in `state`.
        public func with(state: RelaunchTargetState, cause: RelaunchCause?) -> Result {
            var copy = Result(key: key, state: state, cause: cause, effectiveID: effectiveID, provider: provider)
            copy.escalation = escalation
            copy.droppedOptions = droppedOptions
            copy.version = version
            copy.model = model
            copy.effort = effort
            copy.backgroundSaved = backgroundSaved
            copy.messageSent = messageSent
            copy.draftRestored = draftRestored
            return copy
        }
    }

    public let operationID: UUID
    public let verb: RelaunchVerb
    /// True when this answer is an operation that already existed.
    ///
    /// It says the operation was **found**, not that it **finished** — a recovered operation can
    /// still be halfway through. What finished is ``state``. Reading one as the other is how a
    /// client ends up showing a tick beside an agent that is still closing.
    public let recovered: Bool
    public let results: [Result]
    /// What `claude update` did on each installation (``RelaunchVerb/agentUpdate`` only).
    public let updates: [RelaunchInstallationUpdate]

    /// Creates an operation.
    ///
    /// - Parameters:
    ///   - operationID: The operation's identifier, the plan's.
    ///   - verb: What it does.
    ///   - recovered: Whether this answer is an operation that already existed.
    ///   - results: Where each target got to.
    ///   - updates: What `claude update` did per installation.
    public init(
        operationID: UUID,
        verb: RelaunchVerb,
        recovered: Bool,
        results: [Result],
        updates: [RelaunchInstallationUpdate] = []
    ) {
        self.operationID = operationID
        self.verb = verb
        self.recovered = recovered
        self.results = results
        self.updates = updates
    }

    /// The operation as it travels in an `apply`/`status` response.
    public var json: [String: Any] {
        var payload: [String: Any] = [
            "operation_id": operationID.uuidString,
            "recovered": recovered,
            "operation_state": state.rawValue,
            "results": results.map(\.json),
        ]
        if verb == .agentUpdate || !updates.isEmpty {
            payload["updates"] = updates.map(\.json)
        }
        return payload
    }

    /// Still going while any target has phases left ahead of it.
    public var state: State {
        let settled: Set<RelaunchTargetState> = [.verified, .failed, .skipped, .needsUser]
        return results.allSatisfy { settled.contains($0.state) } ? .finished : .running
    }

    /// The targets a person has to attend to before they can finish.
    public var needingUser: [Result] { results.filter { $0.state == .needsUser } }

    /// The targets worth trying again. Retrying is per target: what worked is not repeated.
    public var retryable: [Result] { results.filter { $0.state == .failed } }
}
