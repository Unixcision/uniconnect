import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - Storage locations

enum UniConnectPaths {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // UniConnect owns its directory. Debug / tagged builds carry their own bundle id and
        // get a suffixed folder so dogfooding never pollutes real data.
        let release = UniConnectIdentity.releaseBundleIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? release
#if DEBUG
        let suffix = bundleId == release
            ? "-debug"
            : "-" + bundleId.replacingOccurrences(of: release + ".", with: "")
#else
        let suffix = bundleId == release
            ? ""
            : "-" + bundleId.replacingOccurrences(of: release + ".", with: "")
#endif
        let dir = base.appendingPathComponent("UniConnect\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static var vaultFile: URL { directory.appendingPathComponent("vault.uc") }
    static var claudeBridgeVaultFile: URL { directory.appendingPathComponent("claude-bridge-vault.uc") }
    /// Tiny markdown document used as the (hidden) placeholder panel of an SSH box that has
    /// no tmux window yet. A non-terminal panel keeps cmux's "one panel per workspace"
    /// invariant without spawning a shell that would grab keyboard focus.
    static var placeholderMarkdownFile: URL {
        let url = directory.appendingPathComponent("caja-ssh-vacia.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let text = String(
                localized: "uniconnect.vault.placeholder.emptySSH",
                defaultValue: "# SSH Box Without Windows\n\nCreate the first window from the UniConnect welcome page (UniConnect ▸ New tmux Window…).\n"
            )
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
    /// Commit marker for the current readable, secret-free manual backup.
    static var backupFile: URL { directory.appendingPathComponent("backup.json") }
    /// Whole-document encrypted backup written by releases before split backup storage.
    static var legacyBackupFile: URL { directory.appendingPathComponent("backup.uc") }
    static var masterKeyFallbackFile: URL { directory.appendingPathComponent(".master-key") }
    static var backupHistoryDirectory: URL {
        let dir = directory.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

// MARK: - Crypto primitives

enum UniConnectCrypto {
    /// Envelope written to disk for every encrypted UniConnect file.
    struct Envelope: Codable {
        var format: String        // "uniconnect-aesgcm"
        var version: Int          // 1
        var kdf: String?          // "pbkdf2-sha256" when passphrase based, nil for master key
        var iterations: Int?
        var salt: String?         // base64
        var nonce: String         // base64 (12 bytes)
        var ciphertext: String    // base64
        var tag: String           // base64 (16 bytes)
    }

    static let formatName = "uniconnect-aesgcm"
    static let pbkdf2Iterations = 600_000

    static func seal(_ plaintext: Data, key: SymmetricKey, kdf: (salt: Data, iterations: Int)? = nil) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data(formatName.utf8))
        let envelope = Envelope(
            format: formatName,
            version: 1,
            kdf: kdf == nil ? nil : "pbkdf2-sha256",
            iterations: kdf?.iterations,
            salt: kdf?.salt.base64EncodedString(),
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func parseEnvelope(_ data: Data) throws -> Envelope {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == formatName else {
            throw UniConnectError.corruptFile(String(
                localized: "uniconnect.vault.error.unknownHeader",
                defaultValue: "unknown header"
            ))
        }
        return envelope
    }

    static func open(_ envelope: Envelope, key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw UniConnectError.corruptFile(String(
                localized: "uniconnect.vault.error.invalidBase64",
                defaultValue: "invalid Base64 fields"
            ))
        }
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(box, using: key, authenticating: Data(formatName.utf8))
        } catch {
            throw UniConnectError.badPassphrase
        }
    }

    static func passphraseKey(_ passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(passphrase.utf8)
        let saltBytes = [UInt8](salt)
        _ = passwordBytes.withUnsafeBufferPointer { pw in
            saltBytes.withUnsafeBufferPointer { s in
                derived.withUnsafeMutableBufferPointer { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        UnsafeRawPointer(pw.baseAddress).map { $0.assumingMemoryBound(to: Int8.self) },
                        pw.count,
                        s.baseAddress,
                        s.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress,
                        out.count
                    )
                }
            }
        }
        return SymmetricKey(data: Data(derived))
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    // Convenience: encrypt/decrypt with a passphrase (export/import).
    static func sealWithPassphrase(_ plaintext: Data, passphrase: String) throws -> Data {
        let salt = randomSalt()
        let key = passphraseKey(passphrase, salt: salt, iterations: pbkdf2Iterations)
        return try seal(plaintext, key: key, kdf: (salt, pbkdf2Iterations))
    }

    static func openWithPassphrase(_ data: Data, passphrase: String) throws -> Data {
        let envelope = try parseEnvelope(data)
        guard envelope.kdf == "pbkdf2-sha256",
              let saltB64 = envelope.salt, let salt = Data(base64Encoded: saltB64),
              let iterations = envelope.iterations else {
            throw UniConnectError.corruptFile(String(
                localized: "uniconnect.vault.error.notPasswordEncrypted",
                defaultValue: "this file is not password-encrypted"
            ))
        }
        let key = passphraseKey(passphrase, salt: salt, iterations: iterations)
        return try open(envelope, key: key)
    }
}

// MARK: - Master key
//
// Release policy:
//  * The login Keychain is the sole source after a one-time verified migration.
//  * A legacy `.master-key` is copied to Keychain, read back byte-for-byte, and only
//    then removed. Any failed verification stops before encrypted data can be rewritten.
// Debug policy:
//  * Tagged builds use their isolated Application Support folder and a mode-0600 file.
//  * Debug never reads or changes the Release Keychain item.

enum UniConnectMasterKey {
    private enum KeychainReadResult {
        case found(Data)
        case missing
        case unavailable(OSStatus)
    }

    private static let service = "com.unixcision.uniconnect.master-key"
    private static let account = "master-key-v1"
    private static var cached: SymmetricKey?

    static func load() -> SymmetricKey {
        if let cached { return cached }
#if DEBUG
        let key = loadIsolatedDebugKey()
#else
        let key = loadReleaseKeychainKey()
#endif
        cached = key
        return key
    }

    private static func loadIsolatedDebugKey() -> SymmetricKey {
        if FileManager.default.fileExists(atPath: UniConnectPaths.masterKeyFallbackFile.path) {
            guard let data = try? UniConnectAtomicFileWriter.readPrivateFile(
                at: UniConnectPaths.masterKeyFallbackFile,
                maximumBytes: 32,
                repairPermissions: true
            ), data.count == 32 else {
                preconditionFailure("UniConnect found an invalid or insecure isolated Debug master key")
            }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try UniConnectAtomicFileWriter.write(data, to: UniConnectPaths.masterKeyFallbackFile)
        } catch {
            preconditionFailure("UniConnect could not persist its isolated Debug master key: \(error)")
        }
        return key
    }

    private static func loadReleaseKeychainKey() -> SymmetricKey {
        let fallbackURL = UniConnectPaths.masterKeyFallbackFile
        let fallbackExists = FileManager.default.fileExists(atPath: fallbackURL.path)
        let fallbackData = fallbackExists
            ? try? UniConnectAtomicFileWriter.readPrivateFile(
                at: fallbackURL,
                maximumBytes: 32,
                repairPermissions: true
            )
            : nil
        let keychainData: Data?
        switch readKeychainNoUI() {
        case .found(let data):
            keychainData = data
        case .missing:
            keychainData = nil
        case .unavailable(let status):
            preconditionFailure(
                "UniConnect could not safely read its Keychain master key (OSStatus \(status)); encrypted data was left untouched"
            )
        }

        switch UniConnectMasterKeyMigrationPolicy.action(
            fallback: fallbackExists ? (fallbackData ?? Data()) : nil,
            keychain: keychainData
        ) {
        case .migrateFallbackToKeychain:
            guard let fallbackData,
                  writeKeychainNoUI(fallbackData),
                  verifiedKeychainData() == fallbackData else {
                preconditionFailure("UniConnect master-key migration to Keychain could not be verified")
            }
            do {
                try FileManager.default.removeItem(at: fallbackURL)
            } catch {
                preconditionFailure("UniConnect verified its Keychain migration but could not remove the plaintext legacy key")
            }
            return SymmetricKey(data: fallbackData)

        case .useKeychain:
            guard let keychainData else {
                preconditionFailure("UniConnect Keychain master key disappeared during loading")
            }
            return SymmetricKey(data: keychainData)

        case .createKeychainKey:
            guard UniConnectMasterKeyMigrationPolicy.permitsNewKey(
                hasExistingEncryptedState: hasExistingMasterKeyEncryptedState()
            ) else {
                preconditionFailure(
                    "UniConnect found encrypted data without its master key and refused to replace it with an unrelated key"
                )
            }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            guard writeKeychainNoUI(data), verifiedKeychainData() == data else {
                preconditionFailure("UniConnect could not create and verify its Keychain master key")
            }
            return key

        case .failInvalidFallback:
            preconditionFailure("UniConnect found an invalid legacy master-key file and refused a lossy migration")

        case .failInvalidKeychain:
            preconditionFailure("UniConnect found an invalid Keychain master key and refused to replace it")
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Runs `body` with legacy-keychain user interaction disabled so a missing ACL
    /// entry fails fast (errSecInteractionNotAllowed) instead of prompting.
    private static func withoutKeychainUI<T>(_ body: () -> T) -> T {
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }

    private static func readKeychainNoUI() -> KeychainReadResult {
        withoutKeychainUI {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else {
                    return .unavailable(errSecDecode)
                }
                return .found(data)
            case errSecItemNotFound:
                return .missing
            default:
                return .unavailable(status)
            }
        }
    }

    private static func verifiedKeychainData() -> Data? {
        guard case .found(let data) = readKeychainNoUI() else { return nil }
        return data
    }

    /// A missing Keychain item is only a first-launch condition when no payload
    /// already depends on it. Creating a fresh key beside old ciphertext would be
    /// indistinguishable from data loss on the next vault read.
    private static func hasExistingMasterKeyEncryptedState() -> Bool {
        let fileManager = FileManager.default
        let directFiles = [
            UniConnectPaths.vaultFile,
            UniConnectPaths.claudeBridgeVaultFile,
            UniConnectPaths.legacyBackupFile,
        ]
        if directFiles.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
            return true
        }

        let importCheckpointDirectory = UniConnectPaths.directory.appendingPathComponent(
            "import-checkpoints",
            isDirectory: true
        )
        if let checkpointNames = try? fileManager.contentsOfDirectory(
            atPath: importCheckpointDirectory.path
        ), checkpointNames.contains(where: { $0.hasSuffix(".uc-checkpoint") }) {
            return true
        }

        let directories = [
            UniConnectPaths.directory,
            UniConnectPaths.backupHistoryDirectory,
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".uniconnect", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true),
        ]
        return directories.contains { directory in
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                return false
            }
            return names.contains { $0.hasSuffix(".uc") }
        }
    }

    private static func writeKeychainNoUI(_ data: Data) -> Bool {
        withoutKeychainUI {
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecAttrLabel as String] = "UniConnect master key"
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let update: [String: Any] = [kSecValueData as String: data]
                return SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary) == errSecSuccess
            }
            return status == errSecSuccess
        }
    }
}

// MARK: - Credential vault (connect commands, encrypted at rest)

final class UniConnectVault {
    static let shared = UniConnectVault()

    private let queue = DispatchQueue(label: "uniconnect.vault")
    private let storageURL: URL
    private let keyProvider: () -> SymmetricKey
    private var entries: [UUID: String] = [:]
    private var loaded = false
    private var loadFailure: Error?

    init(
        storageURL: URL = UniConnectPaths.vaultFile,
        keyProvider: @escaping () -> SymmetricKey = { UniConnectMasterKey.load() }
    ) {
        self.storageURL = storageURL
        self.keyProvider = keyProvider
    }

    @discardableResult
    private func loadIfNeeded() -> Bool {
        guard !loaded else { return loadFailure == nil }
        loaded = true
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return true }
        do {
            let data = try UniConnectAtomicFileWriter.readPrivateFile(
                at: storageURL,
                repairPermissions: true
            )
            let envelope = try UniConnectCrypto.parseEnvelope(data)
            let plaintext = try UniConnectCrypto.open(envelope, key: keyProvider())
            entries = try Self.decodeEntries(plaintext)
            return true
        } catch {
            loadFailure = error
            NSLog("[UniConnect] vault unreadable: \(error)")
            return false
        }
    }

    private func persist() throws {
        let payload = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try UniConnectCrypto.seal(plaintext, key: keyProvider())
        try UniConnectAtomicFileWriter.write(sealed, to: storageURL)
    }

    func connectCommand(for id: UUID) -> String? {
        queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries[id]
        }
    }

    /// Finds an existing immutable credential during checkpoint restoration.
    func credentialID(matching connectCommand: String, excluding excludedID: UUID?) -> UUID? {
        let normalized = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries.keys
                .filter { $0 != excludedID && entries[$0] == normalized }
                .sorted { $0.uuidString < $1.uuidString }
                .first
        }
    }

    /// Creates a durable encrypted credential revision that updater recovery can keep using.
    ///
    /// The revision identifier is derived from the source ID and exact command, while the command
    /// itself remains only inside the encrypted vault. Editing or deleting the workspace's active
    /// credential therefore cannot retarget an already-confirmed recovery obligation.
    func immutableRevision(for sourceID: UUID) throws -> UUID {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            guard let command = entries[sourceID] else {
                throw UniConnectError.missingCredential
            }
            let revisionID = Self.revisionID(sourceID: sourceID, command: command)
            if let existing = entries[revisionID] {
                guard existing == command else {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.revisionCollision",
                        defaultValue: "credential revision collision"
                    ))
                }
                return revisionID
            }
            entries[revisionID] = command
            do {
                try persist()
            } catch {
                entries.removeValue(forKey: revisionID)
                throw error
            }
            return revisionID
        }
    }

    @discardableResult
    func store(connectCommand: String, id: UUID = UUID()) -> UUID {
        do {
            return try storeOrThrow(connectCommand: connectCommand, id: id)
        } catch {
            NSLog("[UniConnect] credential vault save failed: \(error)")
            return id
        }
    }

    /// Persists a connection transactionally so callers never publish a vault
    /// reference whose encrypted value was not durably committed.
    @discardableResult
    func storeOrThrow(connectCommand: String, id: UUID = UUID()) throws -> UUID {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            let normalized = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = entries[id]
            // Preserve the exact encrypted checkpoint bytes during rollback and avoid
            // needless vault churn when an import reasserts the same credential.
            if previous == normalized { return id }
            entries[id] = normalized
            do {
                try persist()
            } catch {
                if let previous {
                    entries[id] = previous
                } else {
                    entries.removeValue(forKey: id)
                }
                throw error
            }
            return id
        }
    }

    /// Creates a fresh immutable credential revision for a connection-profile edit.
    ///
    /// Existing IDs are never overwritten: live windows, Closed Items, and recovery
    /// snapshots that still reference the previous revision continue to resolve to the
    /// exact endpoint they captured.
    @discardableResult
    func createImmutableRevision(
        connectCommand: String,
        id: UUID = UUID()
    ) throws -> UUID {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            guard entries[id] == nil else {
                throw UniConnectError.corruptFile(String(
                    localized: "uniconnect.vault.error.revisionIdentifierCollision",
                    defaultValue: "credential revision identifier collision"
                ))
            }
            let normalized = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw UniConnectError.missingCredential
            }
            entries[id] = normalized
            do {
                try persist()
            } catch {
                entries.removeValue(forKey: id)
                throw error
            }
            return id
        }
    }

    func remove(id: UUID) {
        queue.sync {
            guard loadIfNeeded() else { return }
            guard let previous = entries.removeValue(forKey: id) else { return }
            do {
                try persist()
            } catch {
                entries[id] = previous
                NSLog("[UniConnect] credential vault save failed: \(error)")
            }
        }
    }

    /// Removes a credential revision and reports persistence failures to transactional callers.
    func removeOrThrow(id: UUID) throws {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            guard let previous = entries.removeValue(forKey: id) else { return }
            do {
                if entries.isEmpty {
                    try UniConnectAtomicFileWriter.removeIfPresent(at: storageURL)
                } else {
                    try persist()
                }
            } catch {
                entries[id] = previous
                throw error
            }
        }
    }

    func allIds() -> [UUID] {
        queue.sync {
            guard loadIfNeeded() else { return [] }
            return Array(entries.keys)
        }
    }

    /// Returns one authenticated ciphertext revision after validating every referenced ID.
    func encryptedSnapshot(requiring credentialIDs: Set<UUID> = []) throws -> Data? {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            guard credentialIDs.allSatisfy({ entries[$0] != nil }) else {
                throw UniConnectError.missingCredential
            }
            guard FileManager.default.fileExists(atPath: storageURL.path) else {
                guard entries.isEmpty else {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.fileMissing",
                        defaultValue: "credential vault file missing"
                    ))
                }
                return nil
            }
            return try UniConnectAtomicFileWriter.readPrivateFile(
                at: storageURL,
                repairPermissions: true
            )
        }
    }

    /// Resolves only the requested commands from an authenticated encrypted snapshot.
    ///
    /// This does not merge or otherwise mutate the live vault. Local backup restore uses
    /// it so an older backup remains bound to its captured immutable revisions even when
    /// the live workspace has since moved to a newer credential.
    func connectCommands(
        fromEncryptedSnapshot encryptedSnapshot: Data?,
        requiring credentialIDs: Set<UUID>
    ) throws -> [UUID: String] {
        try queue.sync {
            let snapshotEntries = try entries(fromEncryptedSnapshot: encryptedSnapshot)
            guard credentialIDs.allSatisfy({ snapshotEntries[$0] != nil }) else {
                throw UniConnectError.missingCredential
            }
            return Dictionary(uniqueKeysWithValues: credentialIDs.compactMap { id in
                snapshotEntries[id].map { (id, $0) }
            })
        }
    }

    /// Builds an authenticated snapshot containing the live vault plus migration-only entries.
    ///
    /// Legacy whole-document backups did not carry opaque credential IDs. Migration assigns
    /// IDs inside the new readable document and seals matching entries without publishing them
    /// into the live vault.
    func encryptedSnapshot(
        including additionalEntries: [UUID: String]
    ) throws -> Data? {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            var snapshotEntries = entries
            for (id, rawCommand) in additionalEntries {
                let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { throw UniConnectError.missingCredential }
                if let existing = snapshotEntries[id], existing != command {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.revisionIdentifierCollision",
                        defaultValue: "credential revision identifier collision"
                    ))
                }
                snapshotEntries[id] = command
            }
            guard !snapshotEntries.isEmpty else { return nil }
            let payload = Dictionary(uniqueKeysWithValues: snapshotEntries.map {
                ($0.key.uuidString, $0.value)
            })
            let plaintext = try JSONEncoder().encode(payload)
            return try UniConnectCrypto.seal(plaintext, key: keyProvider())
        }
    }

    /// Reverts only vault entries changed by an import, preserving concurrent revisions.
    ///
    /// Plain connection commands remain inside the vault queue. Callers exchange only
    /// authenticated ciphertext captured before and after the import mutation.
    @discardableResult
    func restoreImportDelta(
        checkpoint encryptedCheckpoint: Data?,
        expected encryptedExpected: Data?
    ) throws -> Data? {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            let checkpoint = try entries(fromEncryptedSnapshot: encryptedCheckpoint)
            let expected = try entries(fromEncryptedSnapshot: encryptedExpected)
            let previous = entries
            var restored = entries
            for id in Set(checkpoint.keys).union(expected.keys) {
                let before = checkpoint[id]
                let imported = expected[id]
                guard before != imported else { continue }
                // An overlapping external edit wins. Revert only when the current value
                // still equals the value written (or removed) by the import.
                guard restored[id] == imported else { continue }
                restored[id] = before
            }
            guard restored != entries else {
                guard FileManager.default.fileExists(atPath: storageURL.path) else {
                    return nil
                }
                return try UniConnectAtomicFileWriter.readPrivateFile(
                    at: storageURL,
                    repairPermissions: true
                )
            }
            entries = restored
            do {
                if restored.isEmpty {
                    try UniConnectAtomicFileWriter.removeIfPresent(at: storageURL)
                } else {
                    try persist()
                }
            } catch {
                entries = previous
                throw error
            }
            guard FileManager.default.fileExists(atPath: storageURL.path) else {
                return nil
            }
            return try UniConnectAtomicFileWriter.readPrivateFile(
                at: storageURL,
                repairPermissions: true
            )
        }
    }

    /// Replaces the vault with checkpoint bytes only after authenticating and decoding them.
    func restoreExactEncryptedSnapshot(_ encryptedSnapshot: Data?) throws {
        try queue.sync {
            let restoredEntries: [UUID: String]
            if let encryptedSnapshot {
                let envelope = try UniConnectCrypto.parseEnvelope(encryptedSnapshot)
                let plaintext = try UniConnectCrypto.open(
                    envelope,
                    key: keyProvider()
                )
                restoredEntries = try Self.decodeEntries(plaintext)
                try UniConnectAtomicFileWriter.write(
                    encryptedSnapshot,
                    to: storageURL
                )
            } else {
                restoredEntries = [:]
                try UniConnectAtomicFileWriter.removeIfPresent(at: storageURL)
            }
            entries = restoredEntries
            loaded = true
            loadFailure = nil
        }
    }

    private func entries(fromEncryptedSnapshot snapshot: Data?) throws -> [UUID: String] {
        guard let snapshot else { return [:] }
        let envelope = try UniConnectCrypto.parseEnvelope(snapshot)
        let plaintext = try UniConnectCrypto.open(
            envelope,
            key: keyProvider()
        )
        return try Self.decodeEntries(plaintext)
    }

    /// Verifies that the vault still has the exact ciphertext captured by a checkpoint.
    func matchesExactEncryptedSnapshot(_ encryptedSnapshot: Data?) -> Bool {
        queue.sync {
            if let encryptedSnapshot {
                guard let current = try? UniConnectAtomicFileWriter.readPrivateFile(
                    at: storageURL,
                    repairPermissions: true
                ) else {
                    return false
                }
                return current == encryptedSnapshot
            }
            return !FileManager.default.fileExists(atPath: storageURL.path)
        }
    }

    /// Merges a backup without ever retargeting an existing immutable credential ID.
    ///
    /// When the same ID names different connection material, the recovered command receives
    /// a deterministic revision ID and the returned map tells the snapshot restorer to use it.
    func mergeEncryptedBackup(_ encrypted: Data) throws -> [UUID: UUID] {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            let envelope = try UniConnectCrypto.parseEnvelope(encrypted)
            let plaintext = try UniConnectCrypto.open(envelope, key: keyProvider())
            let backupEntries = try Self.decodeEntries(plaintext)
            let previous = entries
            var remappedIDs: [UUID: UUID] = [:]
            var changed = false
            for id in backupEntries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let command = backupEntries[id] else { continue }
                if let current = entries[id] {
                    if current == command {
                        remappedIDs[id] = id
                        continue
                    }
                    let revisionID = Self.recoveryRevisionID(sourceID: id, command: command)
                    if let revision = entries[revisionID], revision != command {
                        entries = previous
                        throw UniConnectError.corruptFile(String(
                            localized: "uniconnect.vault.error.recoveryRevisionCollision",
                            defaultValue: "credential recovery revision collision"
                        ))
                    }
                    if entries[revisionID] == nil {
                        entries[revisionID] = command
                        changed = true
                    }
                    remappedIDs[id] = revisionID
                } else {
                    entries[id] = command
                    remappedIDs[id] = id
                    changed = true
                }
            }
            if changed {
                do {
                    try persist()
                } catch {
                    entries = previous
                    throw error
                }
            }
            return remappedIDs
        }
    }

    private static func decodeEntries(_ plaintext: Data) throws -> [UUID: String] {
        let decoded = try JSONDecoder().decode([String: String].self, from: plaintext)
        return decoded.reduce(into: [UUID: String]()) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
    }

    private static func revisionID(sourceID: UUID, command: String) -> UUID {
        let material = "uniconnect-updater-credential-v1\0"
            + sourceID.uuidString.lowercased()
            + "\0"
            + command
        let hex = SHA256.hash(data: Data(material.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: value)!
    }

    private static func recoveryRevisionID(sourceID: UUID, command: String) -> UUID {
        let material = "uniconnect-recovery-credential-v1\0"
            + sourceID.uuidString.lowercased()
            + "\0"
            + command
        let hex = SHA256.hash(data: Data(material.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: value)!
    }
}
