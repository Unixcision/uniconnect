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
        do {
            try UniConnectAtomicFileWriter.ensurePrivateDirectory(at: dir)
        } catch {
            preconditionFailure("UniConnect refused an insecure private-storage path: \(error)")
        }
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
            try? UniConnectAtomicFileWriter.write(Data(text.utf8), to: url)
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
        do {
            try UniConnectAtomicFileWriter.ensurePrivateDirectory(at: dir)
        } catch {
            preconditionFailure("UniConnect refused an insecure backup-history path: \(error)")
        }
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
        // Local releases use the login Keychain: the data-protection backend requires
        // provisioned access-group entitlements, which these signed builds do not carry.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private struct Payload: Codable {
        static let formatName = "uniconnect-ssh-credential-vault"
        static let currentVersion = 1

        let format: String
        let version: Int
        let entries: [String: UniConnectSSHCredentialRecord]

        init(entries: [String: UniConnectSSHCredentialRecord]) {
            format = Self.formatName
            version = Self.currentVersion
            self.entries = entries
        }
    }

    private let queue = DispatchQueue(label: "uniconnect.vault")
    private let storageURL: URL
    private let keyProvider: () -> SymmetricKey
    private var entries: [UUID: UniConnectSSHCredentialRecord] = [:]
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
        let plaintext = try Self.encodeEntries(entries)
        let sealed = try UniConnectCrypto.seal(plaintext, key: keyProvider())
        try UniConnectAtomicFileWriter.write(sealed, to: storageURL)
    }

    func connectCommand(for id: UUID) -> String? {
        queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries[id]?.connectCommand
        }
    }

    func credentialRecord(for id: UUID) -> UniConnectSSHCredentialRecord? {
        queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries[id]
        }
    }

    private enum LegacyTargetMigrationError: Error {
        case concurrentChange
        case backupVerificationFailed
    }

    /// Adds the first resolved endpoint to legacy records without changing their identity.
    ///
    /// This is a schema migration, not a connection edit: UUIDs and exact commands stay
    /// unchanged, and a non-nil target is never re-resolved or overwritten. The original
    /// encrypted generation is durably backed up before committing the additive metadata.
    /// Resolution runs outside the vault queue; the commit compares both records and disk
    /// bytes so an intervening edit cannot be overwritten. Unresolvable records stay intact.
    @discardableResult
    func hydrateLegacyEffectiveTargets(
        resolving resolve: ([UniConnectSSHTargetResolutionRequest]) -> [UniConnectSSHTargetResolutionOutcome]
    ) throws -> Int {
        let prepared: (records: [UUID: UniConnectSSHCredentialRecord], ciphertext: Data?) = try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            let legacy = entries.filter { $0.value.effectiveTarget == nil }
            guard !legacy.isEmpty else { return ([:], nil) }
            return (legacy, try UniConnectAtomicFileWriter.readPrivateFile(at: storageURL))
        }
        guard let ciphertext = prepared.ciphertext else { return 0 }
        let validator = UniConnectSSHConnectCommandValidator()
        let candidates = prepared.records.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap {
            entry -> (id: UUID, record: UniConnectSSHCredentialRecord, request: UniConnectSSHTargetResolutionRequest)? in
            guard let command = validator.validatedCommand(entry.value.connectCommand),
                  let request = command.targetResolutionRequest() else { return nil }
            return (entry.key, entry.value, request)
        }
        guard !candidates.isEmpty else { return 0 }
        let outcomes = resolve(candidates.map(\.request))
        guard outcomes.count == candidates.count else { return 0 }

        return try queue.sync {
            guard try UniConnectAtomicFileWriter.readPrivateFile(at: storageURL) == ciphertext,
                  prepared.records.allSatisfy({ entries[$0.key] == $0.value }) else {
                throw LegacyTargetMigrationError.concurrentChange
            }
            var replacements: [UUID: UniConnectSSHCredentialRecord] = [:]
            for (candidate, outcome) in zip(candidates, outcomes) {
                guard case .resolved(let target) = outcome else { continue }
                replacements[candidate.id] = UniConnectSSHCredentialRecord(
                    connectCommand: candidate.record.connectCommand,
                    effectiveTarget: target
                )
            }
            guard !replacements.isEmpty else { return 0 }

            let backupURL = storageURL.deletingLastPathComponent().appendingPathComponent(
                "vault-before-target-migration-\(UUID().uuidString.lowercased()).uc"
            )
            try UniConnectAtomicFileWriter.write(ciphertext, to: backupURL)
            guard try UniConnectAtomicFileWriter.readPrivateFile(at: backupURL) == ciphertext else {
                throw LegacyTargetMigrationError.backupVerificationFailed
            }
            let previous = entries
            entries.merge(replacements) { _, migrated in migrated }
            do {
                try persist()
            } catch {
                entries = previous
                throw error
            }
            return replacements.count
        }
    }

    func effectiveTarget(for id: UUID) -> UniConnectSSHEffectiveTarget? {
        credentialRecord(for: id)?.effectiveTarget
    }

    /// Finds an exact immutable credential revision, including its resolved endpoint.
    func credentialID(
        matching record: UniConnectSSHCredentialRecord,
        excluding excludedID: UUID?
    ) -> UUID? {
        let normalized = Self.normalizedRecord(record)
        return queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries.keys
                .filter { $0 != excludedID && entries[$0] == normalized }
                .sorted { $0.uuidString < $1.uuidString }
                .first
        }
    }

    /// Finds an existing legacy command-only credential during checkpoint restoration.
    ///
    /// Records with a resolved endpoint deliberately do not match: a command-only caller cannot
    /// prove that the same SSH alias still names that endpoint. New callers should use the exact
    /// record overload above.
    func credentialID(matching connectCommand: String, excluding excludedID: UUID?) -> UUID? {
        let normalized = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard loadIfNeeded() else { return nil }
            return entries.keys
                .filter {
                    $0 != excludedID
                        && entries[$0]?.connectCommand == normalized
                        && entries[$0]?.effectiveTarget == nil
                }
                .sorted { $0.uuidString < $1.uuidString }
                .first
        }
    }

    /// Creates a durable encrypted credential revision that updater recovery can keep using.
    ///
    /// The revision identifier is derived from the source ID and complete credential record. Both
    /// the command and resolved endpoint remain only inside the encrypted vault, so an alias that
    /// later resolves elsewhere cannot retarget an already-confirmed recovery obligation.
    func immutableRevision(for sourceID: UUID) throws -> UUID {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            guard let record = entries[sourceID] else {
                throw UniConnectError.missingCredential
            }
            let revisionID = try Self.revisionID(sourceID: sourceID, record: record)
            if let existing = entries[revisionID] {
                guard existing == record else {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.revisionCollision",
                        defaultValue: "credential revision collision"
                    ))
                }
                return revisionID
            }
            entries[revisionID] = record
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

    @discardableResult
    func store(
        connectCommand: String,
        effectiveTarget: UniConnectSSHEffectiveTarget?,
        id: UUID = UUID()
    ) -> UUID {
        do {
            return try storeOrThrow(
                connectCommand: connectCommand,
                effectiveTarget: effectiveTarget,
                id: id
            )
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
            // A command-only caller cannot prove that a changed alias still names the
            // endpoint captured by a target-aware record. Never silently downgrade it.
            if let existing = entries[id], existing.effectiveTarget != nil {
                guard existing.connectCommand == normalized else {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.revisionIdentifierCollision",
                        defaultValue: "credential revision identifier collision"
                    ))
                }
                return id
            }
            return try storeRecordLocked(
                UniConnectSSHCredentialRecord(
                    connectCommand: normalized,
                    effectiveTarget: nil
                ),
                id: id
            )
        }
    }

    /// Persists both the private connection command and its resolved endpoint atomically.
    @discardableResult
    func storeOrThrow(
        connectCommand: String,
        effectiveTarget: UniConnectSSHEffectiveTarget?,
        id: UUID = UUID()
    ) throws -> UUID {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            let record = Self.normalizedRecord(UniConnectSSHCredentialRecord(
                connectCommand: connectCommand,
                effectiveTarget: effectiveTarget
            ))
            return try storeRecordLocked(record, id: id)
        }
    }

    private func storeRecordLocked(
        _ record: UniConnectSSHCredentialRecord,
        id: UUID
    ) throws -> UUID {
        guard !record.connectCommand.isEmpty else {
            throw UniConnectError.missingCredential
        }
        let previous = entries[id]
        // Preserve the exact encrypted checkpoint bytes during rollback and avoid
        // needless vault churn when an import reasserts the same credential.
        if previous == record { return id }
        entries[id] = record
        do {
            try persist()
        } catch {
            // No half-published record remains reachable after an atomic write failure.
            if let previous {
                entries[id] = previous
            } else {
                entries.removeValue(forKey: id)
            }
            throw error
        }
        return id
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
        try createImmutableRevision(
            connectCommand: connectCommand,
            effectiveTarget: nil,
            id: id
        )
    }

    /// Creates a fresh immutable credential revision with its resolved endpoint.
    @discardableResult
    func createImmutableRevision(
        connectCommand: String,
        effectiveTarget: UniConnectSSHEffectiveTarget?,
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
            entries[id] = UniConnectSSHCredentialRecord(
                connectCommand: normalized,
                effectiveTarget: effectiveTarget
            )
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
                snapshotEntries[id].map { (id, $0.connectCommand) }
            })
        }
    }

    /// Resolves complete credential records from an authenticated encrypted snapshot.
    func credentialRecords(
        fromEncryptedSnapshot encryptedSnapshot: Data?,
        requiring credentialIDs: Set<UUID>
    ) throws -> [UUID: UniConnectSSHCredentialRecord] {
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
                if let existing = snapshotEntries[id] {
                    guard existing.connectCommand == command else {
                        throw UniConnectError.corruptFile(String(
                            localized: "uniconnect.vault.error.revisionIdentifierCollision",
                            defaultValue: "credential revision identifier collision"
                        ))
                    }
                    continue
                }
                snapshotEntries[id] = UniConnectSSHCredentialRecord(
                    connectCommand: command,
                    effectiveTarget: nil
                )
            }
            guard !snapshotEntries.isEmpty else { return nil }
            let plaintext = try Self.encodeEntries(snapshotEntries)
            return try UniConnectCrypto.seal(plaintext, key: keyProvider())
        }
    }


    /// Builds an authenticated snapshot with additional complete credential records.
    func encryptedSnapshot(
        including additionalRecords: [UUID: UniConnectSSHCredentialRecord]
    ) throws -> Data? {
        try queue.sync {
            guard loadIfNeeded() else {
                throw loadFailure ?? UniConnectError.vaultLocked
            }
            var snapshotEntries = entries
            for (id, rawRecord) in additionalRecords {
                let record = Self.normalizedRecord(rawRecord)
                guard !record.connectCommand.isEmpty else {
                    throw UniConnectError.missingCredential
                }
                if let existing = snapshotEntries[id], existing != record {
                    throw UniConnectError.corruptFile(String(
                        localized: "uniconnect.vault.error.revisionIdentifierCollision",
                        defaultValue: "credential revision identifier collision"
                    ))
                }
                snapshotEntries[id] = record
            }
            guard !snapshotEntries.isEmpty else { return nil }
            let plaintext = try Self.encodeEntries(snapshotEntries)
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
            let restoredEntries: [UUID: UniConnectSSHCredentialRecord]
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

    private func entries(
        fromEncryptedSnapshot snapshot: Data?
    ) throws -> [UUID: UniConnectSSHCredentialRecord] {
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
    /// When the same ID names different connection material, the recovered record receives a
    /// deterministic revision ID and the returned map tells the snapshot restorer to use it.
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
                guard let record = backupEntries[id] else { continue }
                if let current = entries[id] {
                    if current == record {
                        remappedIDs[id] = id
                        continue
                    }
                    let revisionID = try Self.recoveryRevisionID(
                        sourceID: id,
                        record: record
                    )
                    if let revision = entries[revisionID], revision != record {
                        entries = previous
                        throw UniConnectError.corruptFile(String(
                            localized: "uniconnect.vault.error.recoveryRevisionCollision",
                            defaultValue: "credential recovery revision collision"
                        ))
                    }
                    if entries[revisionID] == nil {
                        entries[revisionID] = record
                        changed = true
                    }
                    remappedIDs[id] = revisionID
                } else {
                    entries[id] = record
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

    private static func encodeEntries(
        _ entries: [UUID: UniConnectSSHCredentialRecord]
    ) throws -> Data {
        let encodedEntries = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.key.uuidString, $0.value)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(entries: encodedEntries))
    }

    private static func decodeEntries(
        _ plaintext: Data
    ) throws -> [UUID: UniConnectSSHCredentialRecord] {
        let decoder = JSONDecoder()
        let decoded: [String: UniConnectSSHCredentialRecord]
        do {
            let payload = try decoder.decode(Payload.self, from: plaintext)
            guard payload.format == Payload.formatName,
                  payload.version == Payload.currentVersion else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Unsupported encrypted SSH credential vault format"
                ))
            }
            decoded = payload.entries
        } catch let payloadError {
            do {
                let legacy = try decoder.decode([String: String].self, from: plaintext)
                decoded = legacy.mapValues {
                    UniConnectSSHCredentialRecord(
                        connectCommand: $0,
                        effectiveTarget: nil
                    )
                }
            } catch {
                throw payloadError
            }
        }
        var result: [UUID: UniConnectSSHCredentialRecord] = [:]
        result.reserveCapacity(decoded.count)
        for (rawID, rawRecord) in decoded {
            guard let id = UUID(uuidString: rawID) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Invalid encrypted SSH credential identifier"
                ))
            }
            let record = normalizedRecord(rawRecord)
            guard !record.connectCommand.isEmpty else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Empty encrypted SSH connection command"
                ))
            }
            guard result[id] == nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Duplicate canonical SSH credential identifier"
                ))
            }
            result[id] = record
        }
        return result
    }

    private static func normalizedRecord(
        _ record: UniConnectSSHCredentialRecord
    ) -> UniConnectSSHCredentialRecord {
        UniConnectSSHCredentialRecord(
            connectCommand: record.connectCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            effectiveTarget: record.effectiveTarget
        )
    }

    private static func revisionID(
        sourceID: UUID,
        record: UniConnectSSHCredentialRecord
    ) throws -> UUID {
        guard record.effectiveTarget != nil else {
            return legacyDerivedRevisionID(
                namespace: "uniconnect-updater-credential-v1",
                sourceID: sourceID,
                command: record.connectCommand
            )
        }
        return try derivedRevisionID(
            namespace: "uniconnect-updater-credential-v2",
            sourceID: sourceID,
            record: record
        )
    }

    private static func recoveryRevisionID(
        sourceID: UUID,
        record: UniConnectSSHCredentialRecord
    ) throws -> UUID {
        guard record.effectiveTarget != nil else {
            return legacyDerivedRevisionID(
                namespace: "uniconnect-recovery-credential-v1",
                sourceID: sourceID,
                command: record.connectCommand
            )
        }
        return try derivedRevisionID(
            namespace: "uniconnect-recovery-credential-v2",
            sourceID: sourceID,
            record: record
        )
    }

    private static func derivedRevisionID(
        namespace: String,
        sourceID: UUID,
        record: UniConnectSSHCredentialRecord
    ) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var material = Data(namespace.utf8)
        material.append(0)
        material.append(contentsOf: sourceID.uuidString.lowercased().utf8)
        material.append(0)
        material.append(try encoder.encode(record))
        return uuid(from: material)
    }

    private static func legacyDerivedRevisionID(
        namespace: String,
        sourceID: UUID,
        command: String
    ) -> UUID {
        let material = namespace
            + "\0"
            + sourceID.uuidString.lowercased()
            + "\0"
            + command
        return uuid(from: Data(material.utf8))
    }

    private static func uuid(from material: Data) -> UUID {
        let hex = SHA256.hash(data: material)
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
