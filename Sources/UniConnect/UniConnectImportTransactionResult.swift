import Foundation

/// The non-sensitive terminal result of an import transaction.
enum UniConnectImportTransactionResult: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case blockedPlan
        case stateChanged
        case invalidSelection
        case remoteSessionsUnavailable([UniConnectImportPlan.WindowID])
        case checkpointFailed
        case journalFailed
        case mutationFailed(rowID: Int)
        case persistenceFailed
        case verificationFailed
        case cancelled
    }

    case noChanges
    case committed(transactionID: UUID, mutatedRowIDs: [Int])
    case rolledBack(transactionID: UUID, failure: Failure)
    case rollbackFailed(transactionID: UUID, originalFailure: Failure)
    case failedBeforeMutation(Failure)
}
