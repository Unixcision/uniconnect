import Foundation

/// The decrypted contents of a pre-import checkpoint.
struct UniConnectImportCheckpoint {
    let id: UUID
    let document: UniConnectDocument
    /// Full secret-sanitized app graph, including browser/markdown panels, splits, IDs, and selection.
    let sessionSnapshot: AppSessionSnapshot
    /// Exact encrypted vault bytes, or nil when no vault existed before import.
    let encryptedVault: Data?
}
