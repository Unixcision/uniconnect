import CryptoKit
import Foundation

/// The passwords windows use to switch user (`run-as.v1`), one per window, encrypted at rest.
///
/// Sealed with the same master key and envelope as the SSH credential vault
/// (``UniConnectVault``), in its own file so the credential export never carries them. Relaunch
/// and recovery read a window's password to switch user again; closing the window removes it.
/// A password is never returned to a client, logged or written anywhere else.
actor UniConnectRunAsPasswordStore {
    private struct Payload: Codable {
        static let formatName = "uniconnect-run-as-passwords"
        static let currentVersion = 1

        let format: String
        let version: Int
        let passwords: [String: String]
    }

    private let storageURL: URL
    private let keyProvider: @Sendable () -> SymmetricKey
    private var passwords: [UUID: String]?

    /// - Parameters:
    ///   - storageURL: The sealed file; tests pass a temporary one.
    ///   - keyProvider: The master key; tests pass a fixed one.
    init(
        storageURL: URL = UniConnectPaths.vaultFile.deletingLastPathComponent()
            .appendingPathComponent("run-as.vault"),
        keyProvider: @escaping @Sendable () -> SymmetricKey = { UniConnectMasterKey.load() }
    ) {
        self.storageURL = storageURL
        self.keyProvider = keyProvider
    }

    /// Keeps `password` for the window `panelID`, replacing any previous one.
    func store(_ password: String, for panelID: UUID) throws {
        var current = try load()
        current[panelID] = password
        try persist(current)
    }

    /// The password of the window `panelID`, or `nil`.
    func password(for panelID: UUID) throws -> String? {
        try load()[panelID]
    }

    /// Forgets the password of a closed window.
    func remove(for panelID: UUID) throws {
        var current = try load()
        guard current.removeValue(forKey: panelID) != nil else { return }
        try persist(current)
    }

    private func load() throws -> [UUID: String] {
        if let passwords { return passwords }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            passwords = [:]
            return [:]
        }
        let data = try UniConnectAtomicFileWriter.readPrivateFile(at: storageURL, repairPermissions: true)
        let plaintext = try UniConnectCrypto.open(UniConnectCrypto.parseEnvelope(data), key: keyProvider())
        let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
        guard payload.format == Payload.formatName, payload.version == Payload.currentVersion else {
            throw UniConnectError.corruptFile(storageURL.lastPathComponent)
        }
        var decoded: [UUID: String] = [:]
        for (key, value) in payload.passwords {
            if let id = UUID(uuidString: key) { decoded[id] = value }
        }
        passwords = decoded
        return decoded
    }

    private func persist(_ updated: [UUID: String]) throws {
        if updated.isEmpty {
            try UniConnectAtomicFileWriter.removeIfPresent(at: storageURL)
        } else {
            let payload = Payload(
                format: Payload.formatName,
                version: Payload.currentVersion,
                passwords: Dictionary(uniqueKeysWithValues: updated.map { ($0.key.uuidString, $0.value) })
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try UniConnectAtomicFileWriter.write(
                UniConnectCrypto.seal(try encoder.encode(payload), key: keyProvider()),
                to: storageURL
            )
        }
        passwords = updated
    }
}
