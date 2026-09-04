import Foundation

/// Serializes CONNECT imports against user and socket mutations of the live session graph.
@MainActor
final class UniConnectImportMutationGate {
    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
    }

    enum AcquisitionError: Error {
        case alreadyHeld
    }

    @TaskLocal private static var currentLeaseID: UUID?

    private var heldLeaseID: UUID?
    private(set) var externalMutationRevision: UInt64 = 0

    var isLocked: Bool { heldLeaseID != nil }

    /// Returns whether the window shortcut entrypoint must consume an event while locked.
    static func shouldConsumeShortcut(allowsMutation: Bool) -> Bool {
        !allowsMutation
    }

    /// Acquires the sole import lease. A second importer fails closed.
    func acquire() throws -> Lease {
        guard heldLeaseID == nil else { throw AcquisitionError.alreadyHeld }
        let lease = Lease(id: UUID())
        heldLeaseID = lease.id
        return lease
    }

    /// Runs work with mutation authority scoped to the current structured task only.
    func withLease<Result>(
        _ lease: Lease,
        operation: () async -> Result
    ) async -> Result? {
        guard heldLeaseID == lease.id else { return nil }
        return await Self.$currentLeaseID.withValue(lease.id) {
            await operation()
        }
    }

    /// Releases a lease only when it is still the active owner.
    @discardableResult
    func release(_ lease: Lease) -> Bool {
        guard heldLeaseID == lease.id else { return false }
        heldLeaseID = nil
        return true
    }

    /// Returns whether the current task may mutate the session graph.
    var allowsMutation: Bool {
        guard let heldLeaseID else { return true }
        return Self.currentLeaseID == heldLeaseID
    }

    /// Registers a model mutation and rejects callers outside the active import lease.
    @discardableResult
    func registerMutation() -> Bool {
        guard allowsMutation else { return false }
        if heldLeaseID == nil {
            externalMutationRevision &+= 1
        }
        return true
    }
}
