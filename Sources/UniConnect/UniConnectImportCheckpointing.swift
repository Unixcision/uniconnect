import Foundation

/// Persists and reloads the encrypted recovery boundary for an import transaction.
protocol UniConnectImportCheckpointing: Sendable {
    func create(
        id: UUID,
        document: UniConnectDocument,
        sessionSnapshot: AppSessionSnapshot,
        encryptedVault: Data?
    ) async throws
    func load(id: UUID) async throws -> UniConnectImportCheckpoint
    func delete(id: UUID) async throws
    func prune(olderThan cutoff: Date) async
}
