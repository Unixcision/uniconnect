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
        /// The conversation proven live afterwards. Only ``RelaunchVerb/agentRelaunch`` has one.
        public let effectiveID: String?

        public init(
            key: RelaunchTargetKey,
            state: RelaunchTargetState,
            cause: RelaunchCause? = nil,
            effectiveID: String? = nil
        ) {
            self.key = key
            self.state = state
            self.cause = cause
            self.effectiveID = effectiveID
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

    public init(operationID: UUID, verb: RelaunchVerb, recovered: Bool, results: [Result]) {
        self.operationID = operationID
        self.verb = verb
        self.recovered = recovered
        self.results = results
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
