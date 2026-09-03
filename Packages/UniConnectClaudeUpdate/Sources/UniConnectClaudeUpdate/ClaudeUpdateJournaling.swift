import Foundation

/// Persists the source of truth for session-restoration obligations.
public protocol ClaudeUpdateJournaling: Sendable {
    /// Inserts or replaces one recovery record durably.
    ///
    /// A successful return must mean the record survives process termination. Implementations
    /// should use atomic replacement and restrictive file permissions.
    ///
    /// - Parameter record: The immutable recovery instruction to persist.
    /// - Throws: When durability cannot be guaranteed.
    func save(_ record: ClaudeUpdateRecoveryRecord) async throws

    /// Removes a recovery obligation after exact resumed-session verification succeeds.
    ///
    /// - Parameters:
    ///   - operationID: The operation that created the obligation.
    ///   - targetID: The target whose exact session was verified.
    /// - Throws: When the durable record cannot be removed.
    func remove(operationID: UUID, targetID: ClaudeUpdateTargetID) async throws

    /// Loads outstanding recovery obligations for crash or relaunch repair.
    ///
    /// - Returns: Records in deterministic persistence order.
    /// - Throws: When the journal cannot be read or decoded safely.
    func pendingRecords() async throws -> [ClaudeUpdateRecoveryRecord]
}
