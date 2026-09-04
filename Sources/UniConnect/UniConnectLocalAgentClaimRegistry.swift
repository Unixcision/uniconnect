import Foundation

/// Serializes pending and active ownership of one restorable local-agent conversation.
@MainActor
final class UniConnectLocalAgentClaimRegistry {
    typealias Claim = UniConnectLocalAgentRestoreClaimPolicy.Claim
    typealias Owner = UniConnectLocalAgentRestoreClaimPolicy.Owner

    enum Phase: Equatable, Sendable {
        case pendingDelivery
        case awaitingCommand
        case active
    }

    struct Lease: Equatable, Sendable {
        let claim: Claim
        let owner: Owner
        let generation: UInt64
    }

    private struct Entry {
        let lease: Lease
        var phase: Phase
    }

    private var entriesByClaim: [Claim: Entry] = [:]
    private var nextGeneration: UInt64 = 0

    /// Reserves a claim before any command can be queued or injected.
    func reserve(_ claim: Claim, for owner: Owner) -> Lease? {
        guard entriesByClaim[claim] == nil,
              !entriesByClaim.values.contains(where: { $0.lease.owner == owner }) else {
            return nil
        }
        nextGeneration &+= 1
        let lease = Lease(claim: claim, owner: owner, generation: nextGeneration)
        entriesByClaim[claim] = Entry(lease: lease, phase: .pendingDelivery)
        return lease
    }

    /// Registers a conversation discovered after a brand-new agent has started.
    /// Re-observing the same owner is idempotent; a different live owner is rejected.
    func registerActive(_ claim: Claim, for owner: Owner) -> Lease? {
        if var entry = entriesByClaim[claim] {
            guard entry.lease.owner == owner else { return nil }
            entry.phase = .active
            entriesByClaim[claim] = entry
            return entry.lease
        }
        guard let lease = reserve(claim, for: owner) else { return nil }
        _ = markActive(lease)
        return lease
    }

    /// Reconciles an observed process identity with an optional launch reservation.
    ///
    /// A reservation for another conversation is released before the observed claim is
    /// registered, preventing a generic `commandRunning` signal from activating the wrong UUID.
    func registerObserved(_ claim: Claim, for owner: Owner, replacing lease: Lease?) -> Lease? {
        if let lease {
            guard lease.owner == owner else { return nil }
            if lease.claim == claim {
                if markActive(lease) { return lease }
                return registerActive(claim, for: owner)
            }
            _ = release(lease)
        } else if let previous = self.lease(for: owner), previous.claim != claim {
            // An exact foreground-process observation is authoritative. This covers a fast
            // `/exit` -> manually typed agent switch even when prompt-idle notification delivery
            // lagged behind the new process observation.
            _ = release(previous)
        }
        return registerActive(claim, for: owner)
    }

    /// Marks that input reached a live terminal and starts the command-observation phase.
    @discardableResult
    func markDelivered(_ lease: Lease) -> Bool {
        guard var entry = entriesByClaim[lease.claim], entry.lease == lease,
              entry.phase != .active else {
            return false
        }
        if entry.phase == .awaitingCommand { return true }
        entry.phase = .awaitingCommand
        entriesByClaim[lease.claim] = entry
        return true
    }

    /// Promotes exactly the generation whose command-running signal was observed.
    @discardableResult
    func markActive(_ lease: Lease) -> Bool {
        guard var entry = entriesByClaim[lease.claim], entry.lease == lease,
              entry.phase == .pendingDelivery || entry.phase == .awaitingCommand else {
            return false
        }
        entry.phase = .active
        entriesByClaim[lease.claim] = entry
        return true
    }

    /// Releases only the matching generation, so stale timeouts cannot evict a newer launch.
    @discardableResult
    func release(_ lease: Lease) -> Bool {
        guard entriesByClaim[lease.claim]?.lease == lease else { return false }
        entriesByClaim.removeValue(forKey: lease.claim)
        return true
    }

    /// Releases every claim held by a closing or detached owner.
    func releaseAll(for owner: Owner) {
        entriesByClaim = entriesByClaim.filter { $0.value.lease.owner != owner }
    }

    /// Reconciles durable `.agent` records without evicting launches that are still in flight.
    /// When corrupt/legacy state contains duplicate owners, the caller's deterministic first
    /// owner wins and every later owner remains unclaimed.
    func reconcileActive(_ desiredOwnersByClaim: [Claim: Owner]) {
        entriesByClaim = entriesByClaim.filter { claim, entry in
            entry.phase != .active || desiredOwnersByClaim[claim] == entry.lease.owner
        }
        for (claim, owner) in desiredOwnersByClaim.sorted(by: Self.claimSort) {
            _ = registerActive(claim, for: owner)
        }
    }

    func conflictingOwner(for claim: Claim, requester: Owner) -> Owner? {
        guard let owner = entriesByClaim[claim]?.lease.owner, owner != requester else {
            return nil
        }
        return owner
    }

    func lease(for owner: Owner) -> Lease? {
        entriesByClaim.values
            .filter { $0.lease.owner == owner }
            .map(\.lease)
            .sorted { $0.generation < $1.generation }
            .first
    }

    func phase(for lease: Lease) -> Phase? {
        guard let entry = entriesByClaim[lease.claim], entry.lease == lease else { return nil }
        return entry.phase
    }

    var claimedConversations: Set<Claim> {
        Set(entriesByClaim.keys)
    }

    private static func claimSort(
        _ lhs: (key: Claim, value: Owner),
        _ rhs: (key: Claim, value: Owner)
    ) -> Bool {
        if lhs.value.workspaceID != rhs.value.workspaceID {
            return lhs.value.workspaceID.uuidString < rhs.value.workspaceID.uuidString
        }
        if lhs.value.panelID != rhs.value.panelID {
            return lhs.value.panelID.uuidString < rhs.value.panelID.uuidString
        }
        if lhs.key.kind != rhs.key.kind {
            return lhs.key.kind.rawValue < rhs.key.kind.rawValue
        }
        return lhs.key.sessionID < rhs.key.sessionID
    }
}
