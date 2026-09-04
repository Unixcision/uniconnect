import Foundation

/// Chooses a fail-closed master-key migration without touching storage.
enum UniConnectMasterKeyMigrationPolicy {
    enum Action: Equatable {
        case useKeychain
        case migrateFallbackToKeychain
        case createKeychainKey
        case failInvalidFallback
        case failInvalidKeychain
    }

    static func action(fallback: Data?, keychain: Data?) -> Action {
        if let fallback {
            return fallback.count == 32 ? .migrateFallbackToKeychain : .failInvalidFallback
        }
        if let keychain {
            return keychain.count == 32 ? .useKeychain : .failInvalidKeychain
        }
        return .createKeychainKey
    }

    /// A new key is safe only when no existing ciphertext could depend on a
    /// missing Keychain entry.
    static func permitsNewKey(hasExistingEncryptedState: Bool) -> Bool {
        !hasExistingEncryptedState
    }
}
