import Foundation

/// Applies one additive recovery snapshot while treating encrypted credentials as a rollback boundary.
@MainActor
struct UniConnectRecoveryRestoreTransaction {
    typealias SnapshotProvider = @MainActor () -> AppSessionSnapshot?
    typealias SnapshotRestorer = @MainActor (AppSessionSnapshot) -> Bool
    typealias CurrentSnapshotArchiver = @MainActor (AppSessionSnapshot, Data?) async throws -> Void
    typealias VaultSnapshotProvider = @MainActor (Set<UUID>) throws -> Data?
    typealias VaultMerger = @MainActor (Data) throws -> [UUID: UUID]
    typealias VaultRestorer = @MainActor (Data?) throws -> Void

    private let snapshotProvider: SnapshotProvider
    private let snapshotRestorer: SnapshotRestorer
    private let currentSnapshotArchiver: CurrentSnapshotArchiver
    private let vaultSnapshotProvider: VaultSnapshotProvider
    private let vaultMerger: VaultMerger
    private let vaultRestorer: VaultRestorer

    init(
        snapshotProvider: @escaping SnapshotProvider,
        snapshotRestorer: @escaping SnapshotRestorer,
        currentSnapshotArchiver: @escaping CurrentSnapshotArchiver,
        vaultSnapshotProvider: @escaping VaultSnapshotProvider,
        vaultMerger: @escaping VaultMerger,
        vaultRestorer: @escaping VaultRestorer
    ) {
        self.snapshotProvider = snapshotProvider
        self.snapshotRestorer = snapshotRestorer
        self.currentSnapshotArchiver = currentSnapshotArchiver
        self.vaultSnapshotProvider = vaultSnapshotProvider
        self.vaultMerger = vaultMerger
        self.vaultRestorer = vaultRestorer
    }

    func execute(
        recoveredSnapshot: AppSessionSnapshot,
        recoveredVault: Data?
    ) async throws {
        let currentSnapshot = snapshotProvider()
        let currentCredentialIDs = currentSnapshot.map {
            UniConnectRecoveryBackupRepository.referencedSSHCredentialIDs(in: $0)
        } ?? []
        let vaultBeforeRestore = try vaultSnapshotProvider(currentCredentialIDs)
        if let currentSnapshot {
            try await currentSnapshotArchiver(currentSnapshot, vaultBeforeRestore)
        }

        do {
            let recoveredCredentialIDs = UniConnectRecoveryBackupRepository
                .referencedSSHCredentialIDs(in: recoveredSnapshot)
            if !recoveredCredentialIDs.isEmpty, recoveredVault == nil {
                throw UniConnectError.missingCredential
            }
            let credentialIDMap = try recoveredVault.map(vaultMerger) ?? [:]
            guard recoveredCredentialIDs.allSatisfy({ credentialIDMap[$0] != nil }) else {
                throw UniConnectError.missingCredential
            }
            let remappedSnapshot = Self.remappingSSHCredentialIDs(
                in: recoveredSnapshot,
                using: credentialIDMap
            )
            guard snapshotRestorer(remappedSnapshot) else {
                throw UniConnectError.corruptFile("empty recovery snapshot")
            }
        } catch {
            // Exact ciphertext restoration also restores the in-memory decoded dictionary.
            // Never leave credentials from a failed recovery mixed into the live vault.
            try vaultRestorer(vaultBeforeRestore)
            throw error
        }
    }

    /// Rebinds recovered SSH profiles to immutable credential revisions created by the merge.
    nonisolated static func remappingSSHCredentialIDs(
        in snapshot: AppSessionSnapshot,
        using credentialIDMap: [UUID: UUID]
    ) -> AppSessionSnapshot {
        var remapped = snapshot
        for windowIndex in remapped.windows.indices {
            for workspaceIndex in remapped.windows[windowIndex].tabManager.workspaces.indices {
                guard var profile = remapped.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex].uniConnect,
                      profile.isSSH,
                      let oldID = profile.credentialId,
                      let newID = credentialIDMap[oldID] else {
                    continue
                }
                profile.credentialId = newID
                remapped.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex].uniConnect = profile
            }
        }
        return remapped
    }
}
