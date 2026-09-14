import Foundation

/// Decides which targets this host may act on, and drops the ones it must not touch twice.
///
/// Two separate problems that look like one:
///
/// 1. **The same target seen twice.** A remote pane reachable from two hosts appears in both
///    inventories. Keyed by the target itself (``RelaunchTargetKey``) the duplicate is visible;
///    keyed by the viewer it is not, and the reader's agent gets relaunched twice.
/// 2. **Which host acts.** Seeing the duplicate is not enough — somebody still has to be the one
///    who does it. Without a resolvable owner the target is skipped, never executed "just in case":
///    two hosts each deciding they are probably the right one is exactly how it gets done twice.
public struct RelaunchTargetAuthority: Sendable {
    /// Identifies the host running this code, so it can tell its own claim from somebody else's.
    public let hostID: String

    public init(hostID: String) { self.hostID = hostID }

    /// The outcome for one candidate target.
    public enum Ruling: Sendable, Equatable {
        /// This host acts on it.
        case act
        /// Another host owns it; it is reported as handled elsewhere rather than repeated here.
        case defer_(to: String)
        /// Nobody owns it. Skipped, untouched.
        case skip(RelaunchCause)
    }

    /// - Parameters:
    ///   - candidates: what this host can see, in the order it would act.
    ///   - owners: for each pane identity, the host entitled to act on it. A pane missing from this
    ///     map has no resolvable owner.
    /// - Returns: one ruling per candidate, in the same order.
    public func rule(
        candidates: [RelaunchTargetKey],
        owners: [String: String]
    ) -> [(key: RelaunchTargetKey, ruling: Ruling)] {
        var seen = Set<String>()
        return candidates.map { key in
            // The same pane listed twice inside one request is still one pane.
            guard seen.insert(key.paneIdentity).inserted else {
                return (key, .skip(.duplicate))
            }
            guard let owner = owners[key.paneIdentity] else {
                return (key, .skip(.noAuthority))
            }
            return (key, owner == hostID ? .act : .defer_(to: owner))
        }
    }
}
