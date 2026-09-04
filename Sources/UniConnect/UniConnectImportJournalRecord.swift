import Foundation

/// A secret-free crash-recovery record for one import transaction.
struct UniConnectImportJournalRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case applying
        case persisting
        case rollingBack
        case rollbackComplete
        case committed
    }

    let transactionID: UUID
    let checkpointID: UUID
    let sourceDigest: String
    let selectedRowIDs: [Int]
    var completedRowIDs: [Int]
    var nextRowID: Int?
    /// Digest of the last graph state produced by this transaction, used for conditional rollback.
    var expectedStateToken: String? = nil
    var phase: Phase
    let createdAt: TimeInterval
    var updatedAt: TimeInterval
}
