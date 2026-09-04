import AppKit
import Foundation
import UniformTypeIdentifiers

/// Orchestrates the user-facing, additive recovery flow around the backup repository.
@MainActor
final class UniConnectRecoveryCoordinator {
    typealias SnapshotProvider = @MainActor () -> AppSessionSnapshot?
    typealias SnapshotRestorer = @MainActor (AppSessionSnapshot) -> Bool
    typealias EncryptedVaultSnapshotProvider = @MainActor (Set<UUID>) throws -> Data?
    typealias EncryptedVaultMerger = @MainActor (Data) throws -> [UUID: UUID]
    typealias EncryptedVaultRestorer = @MainActor (Data?) throws -> Void

    private let repository: UniConnectRecoveryBackupRepository
    private let snapshotProvider: SnapshotProvider
    private let snapshotRestorer: SnapshotRestorer
    private let encryptedVaultSnapshotProvider: EncryptedVaultSnapshotProvider
    private let encryptedVaultMerger: EncryptedVaultMerger
    private let encryptedVaultRestorer: EncryptedVaultRestorer

    init(
        repository: UniConnectRecoveryBackupRepository,
        snapshotProvider: @escaping SnapshotProvider,
        snapshotRestorer: @escaping SnapshotRestorer,
        encryptedVaultSnapshotProvider: @escaping EncryptedVaultSnapshotProvider,
        encryptedVaultMerger: @escaping EncryptedVaultMerger,
        encryptedVaultRestorer: @escaping EncryptedVaultRestorer
    ) {
        self.repository = repository
        self.snapshotProvider = snapshotProvider
        self.snapshotRestorer = snapshotRestorer
        self.encryptedVaultSnapshotProvider = encryptedVaultSnapshotProvider
        self.encryptedVaultMerger = encryptedVaultMerger
        self.encryptedVaultRestorer = encryptedVaultRestorer
    }

    func presentRestorePicker() {
        let panel = NSOpenPanel()
        panel.title = String(
            localized: "uniconnect.recovery.open.title",
            defaultValue: "Restore a UniConnect Backup"
        )
        panel.message = String(
            localized: "uniconnect.recovery.open.message",
            defaultValue: "Choose one of the automatic recovery snapshots. Your current windows will remain open."
        )
        panel.prompt = String(
            localized: "uniconnect.recovery.open.action",
            defaultValue: "Restore"
        )
        panel.directoryURL = UniConnectRecoveryBackupRepository.defaultRootDirectory()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let snapshotURL = panel.url else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let recoveredSnapshot = await repository.loadSnapshot(from: snapshotURL) else {
                Self.presentInvalidBackupAlert()
                return
            }

            guard Self.confirmRestore() else { return }

            do {
                let recoveredVault = try await repository.loadEncryptedVault(for: snapshotURL)
                let transaction = UniConnectRecoveryRestoreTransaction(
                    snapshotProvider: snapshotProvider,
                    snapshotRestorer: snapshotRestorer,
                    currentSnapshotArchiver: { [repository] snapshot, encryptedVault in
                        _ = try await repository.archive(
                            snapshot: snapshot,
                            encryptedVault: encryptedVault,
                            reason: .beforeRestore
                        )
                    },
                    vaultSnapshotProvider: encryptedVaultSnapshotProvider,
                    vaultMerger: encryptedVaultMerger,
                    vaultRestorer: encryptedVaultRestorer
                )
                try await transaction.execute(
                    recoveredSnapshot: recoveredSnapshot,
                    recoveredVault: recoveredVault
                )
            } catch {
                Self.presentRecoveryFailureAlert(error)
            }
        }
    }

    private static func confirmRestore() -> Bool {
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = String(
            localized: "uniconnect.recovery.confirm.title",
            defaultValue: "Restore this backup?"
        )
        confirmation.informativeText = String(
            localized: "uniconnect.recovery.confirm.message",
            defaultValue: "Recovered boxes and windows will open alongside your current work. Missing SSH credentials will be merged from the encrypted companion backup when available."
        )
        confirmation.addButton(withTitle: String(
            localized: "uniconnect.recovery.confirm.action",
            defaultValue: "Restore"
        ))
        confirmation.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return confirmation.runModal() == .alertFirstButtonReturn
    }

    private static func presentInvalidBackupAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "uniconnect.recovery.invalid.title",
            defaultValue: "This backup cannot be restored"
        )
        alert.informativeText = String(
            localized: "uniconnect.recovery.invalid.message",
            defaultValue: "The selected file is outside UniConnect's recovery archive, damaged, or uses an unsupported format."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private static func presentRecoveryFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "uniconnect.recovery.failed.title",
            defaultValue: "Recovery failed safely"
        )
        alert.informativeText = String(
            format: String(
                localized: "uniconnect.recovery.failed.message",
                defaultValue: "Nothing was replaced. %@"
            ),
            locale: .current,
            error.localizedDescription
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
