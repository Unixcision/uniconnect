import Foundation

/// Binds a plan to the device that asked for it, the verb, and the exact targets it saw.
///
/// All four have to travel together. A token carrying only an operation identifier would let a plan
/// made minutes ago act on panes that did not exist when it was drawn, or let a second device
/// spend somebody else's plan.
public struct RelaunchToken: Sendable, Equatable {
    /// The approved device that asked for the plan.
    public let deviceID: String
    public let operationID: UUID
    public let verb: RelaunchVerb
    /// Every target of the plan, with the generation each one had at that moment.
    public let targets: Set<RelaunchTargetKey>
    public let expiresAt: Date

    public init(
        deviceID: String,
        operationID: UUID,
        verb: RelaunchVerb,
        targets: Set<RelaunchTargetKey>,
        expiresAt: Date
    ) {
        self.deviceID = deviceID
        self.operationID = operationID
        self.verb = verb
        self.targets = targets
        self.expiresAt = expiresAt
    }

    /// Whether the token has run out at `now`.
    public func hasExpired(at now: Date) -> Bool { now >= expiresAt }

    /// Whether this token was issued to `deviceID` for `verb`.
    public func belongs(to deviceID: String, verb: RelaunchVerb) -> Bool {
        self.deviceID == deviceID && self.verb == verb
    }
}
