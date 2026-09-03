import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - Storage locations

enum UniConnectPaths {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // Debug / tagged builds carry their own bundle id; keep their vault and backups apart
        // from the production app so dogfooding never pollutes real data.
        let bundleId = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let suffix = bundleId == "com.cmuxterm.app" ? "" : "-" + bundleId.replacingOccurrences(of: "com.cmuxterm.app.", with: "")
        let dir = base.appendingPathComponent("cmux/uniconnect\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var vaultFile: URL { directory.appendingPathComponent("vault.uc") }
    /// Tiny markdown document used as the (hidden) placeholder panel of an SSH box that has
    /// no tmux window yet. A non-terminal panel keeps cmux's "one panel per workspace"
    /// invariant without spawning a shell that would grab keyboard focus.
    static var placeholderMarkdownFile: URL {
        let url = directory.appendingPathComponent("caja-ssh-vacia.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let text = "# Caja SSH sin ventanas\n\nCrea la primera ventana desde la página de bienvenida de UniConnect (menú UniConnect ▸ Nueva ventana tmux…).\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
    static var backupFile: URL { directory.appendingPathComponent("backup.uc") }
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
            throw UniConnectError.corruptFile("cabecera desconocida")
        }
        return envelope
    }

    static func open(_ envelope: Envelope, key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw UniConnectError.corruptFile("campos base64")
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
            throw UniConnectError.corruptFile("este fichero no va cifrado con contraseña")
        }
        let key = passphraseKey(passphrase, salt: salt, iterations: iterations)
        return try open(envelope, key: key)
    }
}

// MARK: - Master key
//
// Storage policy (documented in docs/UNICONNECT.md §6):
//  * Primary copy: `.master-key` (32 random bytes, mode 0600) inside the UniConnect
//    directory. It is protected by the macOS account, FileVault and the app lock.
//  * Mirror: the login Keychain, best effort and **never interactive**. Ad-hoc signed
//    builds change identity on every rebuild, which would otherwise trigger the
//    "wants to access the keychain" password prompt (a hard hang when the screen is
//    locked) and would strand the vault behind an unreadable key.
//  * Both copies are written; reads prefer the file so the vault stays readable across
//    rebuilds and reinstalls. Deleting both copies makes every vault/backup unreadable.

enum UniConnectMasterKey {
    private static let service = "com.cmuxterm.app.uniconnect"
    private static let account = "master-key-v1"
    private static var cached: SymmetricKey?

    static func load() -> SymmetricKey {
        if let cached { return cached }
        if let data = try? Data(contentsOf: UniConnectPaths.masterKeyFallbackFile), data.count == 32 {
            let key = SymmetricKey(data: data)
            cached = key
            return key
        }
        if let data = readKeychainNoUI(), data.count == 32 {
            let key = SymmetricKey(data: data)
            writeFile(data)
            cached = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        writeFile(data)
        _ = writeKeychainNoUI(data)
        cached = key
        return key
    }

    private static func writeFile(_ data: Data) {
        let url = UniConnectPaths.masterKeyFallbackFile
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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

    private static func readKeychainNoUI() -> Data? {
        withoutKeychainUI {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { return nil }
            return result as? Data
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
    private var entries: [UUID: String] = [:]
    private var loaded = false

    private init() {}

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: UniConnectPaths.vaultFile) else { return }
        do {
            let envelope = try UniConnectCrypto.parseEnvelope(data)
            let plaintext = try UniConnectCrypto.open(envelope, key: UniConnectMasterKey.load())
            let decoded = try JSONDecoder().decode([String: String].self, from: plaintext)
            var map: [UUID: String] = [:]
            for (key, value) in decoded {
                if let id = UUID(uuidString: key) { map[id] = value }
            }
            entries = map
        } catch {
            NSLog("[UniConnect] vault unreadable: \(error)")
        }
    }

    private func persist() {
        let payload = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        guard let plaintext = try? JSONEncoder().encode(payload),
              let sealed = try? UniConnectCrypto.seal(plaintext, key: UniConnectMasterKey.load()) else { return }
        try? sealed.write(to: UniConnectPaths.vaultFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: UniConnectPaths.vaultFile.path)
    }

    func connectCommand(for id: UUID) -> String? {
        queue.sync {
            loadIfNeeded()
            return entries[id]
        }
    }

    @discardableResult
    func store(connectCommand: String, id: UUID = UUID()) -> UUID {
        queue.sync {
            loadIfNeeded()
            entries[id] = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
            return id
        }
    }

    func remove(id: UUID) {
        queue.sync {
            loadIfNeeded()
            entries.removeValue(forKey: id)
            persist()
        }
    }

    func allIds() -> [UUID] {
        queue.sync {
            loadIfNeeded()
            return Array(entries.keys)
        }
    }
}
