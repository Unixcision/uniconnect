import Foundation

/// Adapts the live app state to the import transaction without leaking UI details into the engine.
@MainActor
protocol UniConnectImportTransactionApplying: AnyObject {
    func currentDocument() async throws -> UniConnectDocument
    func currentStateToken() async throws -> String
    func createCheckpoint(id: UUID) async throws
    func deleteCheckpoint(id: UUID) async throws
    func pruneCheckpoints(olderThan cutoff: Date) async
    func apply(_ mutation: UniConnectImportMutation) async throws
    func verifyApplied(_ mutation: UniConnectImportMutation) async throws -> Bool
    func finalizeVerified(_ mutation: UniConnectImportMutation) async throws
    func persistDurably() async throws
    func verifyCommitted(_ mutations: [UniConnectImportMutation]) async throws -> Bool
    func rollback(to checkpointID: UUID, expectedStateToken: String?) async throws
    func verifyRolledBack(to checkpointID: UUID) async throws -> Bool
}
