import Foundation

/// What an incoming `relaunch.apply` turns out to be.
public enum RelaunchAdmission: Sendable, Equatable {
    /// A first execution. `excluded` are targets the plan listed that no longer match what is live,
    /// so they are dropped before anything is touched and the rest still runs.
    case execute(targets: [RelaunchTargetKey], excluded: [(key: RelaunchTargetKey, cause: RelaunchCause)])

    /// This operation already exists. Nothing is executed again; its current state is returned.
    case recover(operationID: UUID)

    /// The call does not proceed at all.
    case reject(RelaunchError)

    public static func == (lhs: RelaunchAdmission, rhs: RelaunchAdmission) -> Bool {
        switch (lhs, rhs) {
        case let (.execute(lt, le), .execute(rt, re)):
            lt == rt && le.map(\.key) == re.map(\.key) && le.map(\.cause) == re.map(\.cause)
        case let (.recover(l), .recover(r)): l == r
        case let (.reject(l), .reject(r)): l == r
        default: false
        }
    }
}

/// Decides whether an `apply` executes, recovers, or is refused.
///
/// This is where the awkward cases live, and they are awkward because the network is. The rule that
/// shapes the rest: **recovering the result of something already done can never require a new
/// plan.** If it did, a cut between closing an agent and hearing back would cost the reader their
/// conversation — the precise failure this whole contract exists to prevent.
///
/// So expiry is checked for *new* work and not for *recovery*. The exception is only to expiry:
/// recovery still demands a device that is approved right now and that owns the operation. A stale
/// token is not a master key.
///
/// ```swift
/// let gate = RelaunchAdmissionGate()
/// let outcome = gate.admit(
///     token: token,
///     requestedBy: "device-a",
///     knownOperations: [:],
///     liveTargets: live,
///     now: .now
/// )
/// ```
public struct RelaunchAdmissionGate: Sendable {
    /// What the host remembers about an operation it already accepted.
    public struct KnownOperation: Sendable, Equatable {
        public let deviceID: String

        public init(deviceID: String) { self.deviceID = deviceID }
    }

    public init() {}

    /// - Parameters:
    ///   - token: the token presented with the `apply`.
    ///   - requestedBy: the device making this call, as authorized *now*.
    ///   - knownOperations: operations already accepted, by identifier.
    ///   - liveTargets: what the host currently sees, keyed by pane identity, with its generation.
    ///   - now: the clock, injected so the expiry rules are testable without waiting.
    public func admit(
        token: RelaunchToken,
        requestedBy requester: String,
        knownOperations: [UUID: KnownOperation],
        liveTargets: [String: RelaunchTargetKey],
        now: Date
    ) -> RelaunchAdmission {
        if let known = knownOperations[token.operationID] {
            // Recovery. Expiry does not apply, ownership and authorization still do.
            guard known.deviceID == requester, token.deviceID == requester else {
                return .reject(.tokenInvalid)
            }
            return .recover(operationID: token.operationID)
        }

        guard token.belongs(to: requester, verb: token.verb) else { return .reject(.tokenInvalid) }
        guard !token.hasExpired(at: now) else { return .reject(.tokenExpired) }

        var run: [RelaunchTargetKey] = []
        var dropped: [(key: RelaunchTargetKey, cause: RelaunchCause)] = []
        for planned in token.targets.sorted(by: { $0.text < $1.text }) {
            guard let live = liveTargets[planned.paneIdentity] else {
                // The pane is gone, so there is nothing to act on and nothing to guess about.
                dropped.append((planned, .generationChanged))
                continue
            }
            if live.generation == planned.generation {
                run.append(planned)
            } else {
                // Somebody else's agent is in that pane now. Acting would relaunch a stranger.
                dropped.append((planned, .generationChanged))
            }
        }
        return .execute(targets: run, excluded: dropped)
    }
}
