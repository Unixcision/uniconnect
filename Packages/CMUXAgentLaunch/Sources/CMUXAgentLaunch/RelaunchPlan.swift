import Foundation

/// What a relaunch would do, handed back before anything is done.
///
/// Two phases exist so the reader can be shown "this touches 26 agents" while it is still a
/// sentence and not a fact. On a phone, the difference between those two is one stray tap.
public struct RelaunchPlan: Sendable, Equatable {
    /// One window the plan intends to act on.
    public struct Target: Sendable, Equatable {
        public let key: RelaunchTargetKey
        /// What the reader calls this window.
        public let label: String
        /// Which agent lives there, so the right adapter is asked for evidence.
        public let provider: String

        public init(key: RelaunchTargetKey, label: String, provider: String) {
            self.key = key
            self.label = label
            self.provider = provider
        }
    }

    /// One window the plan deliberately leaves alone, and why.
    public struct Exclusion: Sendable, Equatable {
        public let label: String
        public let cause: RelaunchCause

        public init(label: String, cause: RelaunchCause) {
            self.label = label
            self.cause = cause
        }
    }

    public let operationID: UUID
    public let verb: RelaunchVerb
    public let targets: [Target]
    /// Never silent. A window left out without a reason reads as a window that was forgotten.
    public let exclusions: [Exclusion]
    public let expiresAt: Date

    public init(
        operationID: UUID,
        verb: RelaunchVerb,
        targets: [Target],
        exclusions: [Exclusion],
        expiresAt: Date
    ) {
        self.operationID = operationID
        self.verb = verb
        self.targets = targets
        self.exclusions = exclusions
        self.expiresAt = expiresAt
    }

    /// How long a fresh plan stands before it has to be asked for again.
    public static let defaultLifetime: TimeInterval = 120
}
