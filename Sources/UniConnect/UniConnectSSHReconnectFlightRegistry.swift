import Foundation

/// Holds one generation-aware reconnect flight per secret-free SSH/tmux target.
@MainActor
final class UniConnectSSHReconnectFlightRegistry {
    struct Lease: Equatable, Sendable {
        let target: UniConnectSSHTargetKey
        let generation: UInt64
    }

    private var leasesByTarget: [UniConnectSSHTargetKey: Lease] = [:]
    private var nextGeneration: UInt64 = 0

    func begin(_ target: UniConnectSSHTargetKey) -> Lease? {
        guard leasesByTarget[target] == nil else { return nil }
        nextGeneration &+= 1
        let lease = Lease(target: target, generation: nextGeneration)
        leasesByTarget[target] = lease
        return lease
    }

    func contains(_ target: UniConnectSSHTargetKey) -> Bool {
        leasesByTarget[target] != nil
    }

    /// Ends only the exact generation so an old stability callback cannot clear its successor.
    @discardableResult
    func finish(_ lease: Lease) -> Bool {
        guard leasesByTarget[lease.target] == lease else { return false }
        leasesByTarget.removeValue(forKey: lease.target)
        return true
    }
}
