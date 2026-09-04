import Foundation

/// Persists encrypted pre-import checkpoints used by normal and crash-time rollback.
actor UniConnectImportCheckpointRepository: UniConnectImportCheckpointing {
    private struct Payload: Codable {
        let version: Int
        let id: UUID
        let document: UniConnectDocument
        let sessionSnapshot: AppSessionSnapshot
        let encryptedVault: Data?
    }

    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = UniConnectPaths.directory.appendingPathComponent(
            "import-checkpoints",
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func create(
        id: UUID,
        document: UniConnectDocument,
        sessionSnapshot: AppSessionSnapshot,
        encryptedVault: Data?
    ) async throws {
        let payload = Payload(
            version: 2,
            id: id,
            document: document,
            sessionSnapshot: SessionPersistenceStore.sanitizedForPersistence(sessionSnapshot),
            encryptedVault: encryptedVault
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(payload)
        let encrypted = try UniConnectCrypto.seal(plaintext, key: UniConnectMasterKey.load())
        try UniConnectAtomicFileWriter.write(encrypted, to: fileURL(for: id))
    }

    func load(id: UUID) async throws -> UniConnectImportCheckpoint {
        let encrypted = try UniConnectAtomicFileWriter.readPrivateFile(
            at: fileURL(for: id),
            repairPermissions: true
        )
        let envelope = try UniConnectCrypto.parseEnvelope(encrypted)
        let plaintext = try UniConnectCrypto.open(envelope, key: UniConnectMasterKey.load())
        let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
        guard payload.version == 2, payload.id == id else {
            throw UniConnectError.corruptFile(String(
                localized: "uniconnect.import.checkpoint.error.invalid",
                defaultValue: "invalid import checkpoint"
            ))
        }
        return UniConnectImportCheckpoint(
            id: payload.id,
            document: payload.document,
            sessionSnapshot: payload.sessionSnapshot,
            encryptedVault: payload.encryptedVault
        )
    }

    func contains(id: UUID) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: id).path)
    }

    func delete(id: UUID) async throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func prune(olderThan cutoff: Date) async {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for item in items where item.pathExtension == "uc-checkpoint" {
            guard let values = try? item.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.contentModificationDate ?? .distantFuture) < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: item)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".uc-checkpoint")
    }
}
