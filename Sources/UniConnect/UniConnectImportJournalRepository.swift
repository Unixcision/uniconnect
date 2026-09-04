import Foundation

/// Stores a bounded, mode-0600 import journal using durable atomic replacement.
actor UniConnectImportJournalRepository: UniConnectImportJournalWriting {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = UniConnectPaths.directory.appendingPathComponent("import-transaction.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() async throws -> UniConnectImportJournalRecord? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try UniConnectAtomicFileWriter.readPrivateFile(
            at: fileURL,
            maximumBytes: 256 * 1_024,
            repairPermissions: true
        )
        return try JSONDecoder().decode(UniConnectImportJournalRecord.self, from: data)
    }

    func save(_ record: UniConnectImportJournalRecord) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try UniConnectAtomicFileWriter.write(try encoder.encode(record), to: fileURL)
    }

    func clear(transactionID: UUID) async throws {
        guard let record = try await load() else { return }
        guard record.transactionID == transactionID else { return }
        try UniConnectAtomicFileWriter.removeIfPresent(at: fileURL)
    }
}
