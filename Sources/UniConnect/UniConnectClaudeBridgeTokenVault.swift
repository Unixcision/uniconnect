import CryptoKit
import Foundation
import UniConnectClaudeBridge

/// Encrypted repository for per-route Claude bridge HMAC tokens.
actor UniConnectClaudeBridgeTokenVault: ClaudeBridgeTokenStoring {
    private struct Entry: Codable, Sendable {
        let token: String
        let credentialID: UUID
    }

    private struct Payload: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]
    }

    private enum VaultError: Error {
        case invalidToken
        case invalidPayload
    }

    private let fileURL: URL
    private let key: SymmetricKey
    private var payload: Payload?

    init(
        fileURL: URL = UniConnectPaths.claudeBridgeVaultFile,
        key: SymmetricKey = UniConnectMasterKey.load()
    ) {
        self.fileURL = fileURL
        self.key = key
    }

    func token(for routeID: UUID) async throws -> Data? {
        let payload = try load()
        guard let encoded = payload.entries[routeID.uuidString.lowercased()]?.token else {
            return nil
        }
        guard let data = Data(base64Encoded: encoded), data.count == 32 else {
            throw VaultError.invalidToken
        }
        return data
    }

    func store(token: Data, for routeID: UUID, credentialID: UUID) async throws {
        guard token.count == 32 else { throw VaultError.invalidToken }
        var updated = try load()
        updated.entries[routeID.uuidString.lowercased()] = Entry(
            token: token.base64EncodedString(),
            credentialID: credentialID
        )
        try persist(updated)
        payload = updated
    }

    func removeToken(for routeID: UUID) async throws {
        var updated = try load()
        guard updated.entries.removeValue(forKey: routeID.uuidString.lowercased()) != nil else {
            return
        }
        try persist(updated)
        payload = updated
    }

    func routeIDs(for credentialID: UUID) async throws -> [UUID] {
        let current = try load()
        return current.entries.compactMap { key, entry in
            guard entry.credentialID == credentialID else { return nil }
            return UUID(uuidString: key)
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private func load() throws -> Payload {
        if let payload { return payload }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Payload(version: 1, entries: [:])
            payload = empty
            return empty
        }
        let encrypted = try UniConnectAtomicFileWriter.readPrivateFile(
            at: fileURL,
            repairPermissions: true
        )
        let envelope = try UniConnectCrypto.parseEnvelope(encrypted)
        let plaintext = try UniConnectCrypto.open(envelope, key: key)
        let decoded = try JSONDecoder().decode(Payload.self, from: plaintext)
        guard decoded.version == 1 else { throw VaultError.invalidPayload }
        payload = decoded
        return decoded
    }

    private func persist(_ payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(payload)
        let encrypted = try UniConnectCrypto.seal(plaintext, key: key)
        try UniConnectAtomicFileWriter.write(encrypted, to: fileURL)
    }
}
