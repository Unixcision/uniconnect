import Foundation

/// Persists the active import journal before and after every mutation boundary.
protocol UniConnectImportJournalWriting: Sendable {
    func load() async throws -> UniConnectImportJournalRecord?
    func save(_ record: UniConnectImportJournalRecord) async throws
    func clear(transactionID: UUID) async throws
}
