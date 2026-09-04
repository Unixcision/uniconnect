import Foundation
import CryptoKit

/// Bridges the side-effect-free import engine to the live app through injected operations.
@MainActor
final class UniConnectLiveImportAdapter: UniConnectImportTransactionApplying {
    typealias DocumentReader = @MainActor () throws -> UniConnectDocument
    typealias SessionSnapshotReader = @MainActor () throws -> AppSessionSnapshot
    typealias MutationApplier = @MainActor (UniConnectImportMutation) throws -> Void
    typealias MutationVerifier = @MainActor (UniConnectImportMutation) async throws -> Bool
    typealias MutationFinalizer = @MainActor (UniConnectImportMutation) throws -> Void
    typealias DurablePersister = @MainActor () throws -> Void
    typealias SessionSnapshotRestorer = @MainActor (AppSessionSnapshot) throws -> Void
    typealias VaultSnapshotReader = @MainActor () throws -> Data?
    typealias VaultRestorer = @MainActor (Data?) throws -> Void
    typealias ConditionalVaultRestorer = @MainActor (Data?, Data?) throws -> Data?
    typealias VaultVerifier = @MainActor (Data?) -> Bool

    private struct StateBundle {
        let snapshot: AppSessionSnapshot
        let encryptedVault: Data?
    }

    private let checkpoints: any UniConnectImportCheckpointing
    private let readDocument: DocumentReader
    private let readCheckpointSnapshot: SessionSnapshotReader
    private let readStateSnapshot: SessionSnapshotReader
    private let applyMutation: MutationApplier
    private let verifyMutation: MutationVerifier
    private let finalizeMutation: MutationFinalizer
    private let persist: DurablePersister
    private let restoreSessionSnapshot: SessionSnapshotRestorer
    private let readVaultSnapshot: VaultSnapshotReader
    private let restoreVault: VaultRestorer
    private let restoreVaultDelta: ConditionalVaultRestorer
    private let verifyVault: VaultVerifier
    private var stateBundlesByToken: [String: StateBundle] = [:]
    private var rollbackTargetTokensByCheckpointID: [UUID: String] = [:]

    init(
        checkpoints: any UniConnectImportCheckpointing,
        readDocument: @escaping DocumentReader,
        readCheckpointSnapshot: @escaping SessionSnapshotReader,
        readStateSnapshot: @escaping SessionSnapshotReader,
        applyMutation: @escaping MutationApplier,
        verifyMutation: @escaping MutationVerifier,
        finalizeMutation: @escaping MutationFinalizer,
        persist: @escaping DurablePersister,
        restoreSessionSnapshot: @escaping SessionSnapshotRestorer,
        readVaultSnapshot: @escaping VaultSnapshotReader,
        restoreVault: @escaping VaultRestorer,
        restoreVaultDelta: @escaping ConditionalVaultRestorer,
        verifyVault: @escaping VaultVerifier
    ) {
        self.checkpoints = checkpoints
        self.readDocument = readDocument
        self.readCheckpointSnapshot = readCheckpointSnapshot
        self.readStateSnapshot = readStateSnapshot
        self.applyMutation = applyMutation
        self.verifyMutation = verifyMutation
        self.finalizeMutation = finalizeMutation
        self.persist = persist
        self.restoreSessionSnapshot = restoreSessionSnapshot
        self.readVaultSnapshot = readVaultSnapshot
        self.restoreVault = restoreVault
        self.restoreVaultDelta = restoreVaultDelta
        self.verifyVault = verifyVault
    }

    func currentDocument() async throws -> UniConnectDocument {
        try readDocument()
    }

    func currentStateToken() async throws -> String {
        let bundle = try readStateBundle()
        let token = try Self.stateToken(
            snapshot: bundle.snapshot,
            encryptedVault: bundle.encryptedVault
        )
        stateBundlesByToken[token] = bundle
        return token
    }

    func createCheckpoint(id: UUID) async throws {
        // Capture the model and its referenced credential revisions in one main-actor
        // turn. The repository only serializes these immutable bytes after the hop.
        let document = try readDocument()
        let sessionSnapshot = try readCheckpointSnapshot()
        let encryptedVault = try readVaultSnapshot()
        try await checkpoints.create(
            id: id,
            document: document,
            sessionSnapshot: sessionSnapshot,
            encryptedVault: encryptedVault
        )
    }

    func deleteCheckpoint(id: UUID) async throws {
        try await checkpoints.delete(id: id)
        stateBundlesByToken.removeAll(keepingCapacity: true)
        rollbackTargetTokensByCheckpointID.removeValue(forKey: id)
    }

    func pruneCheckpoints(olderThan cutoff: Date) async {
        await checkpoints.prune(olderThan: cutoff)
    }

    func apply(_ mutation: UniConnectImportMutation) async throws {
        try applyMutation(mutation)
    }

    func verifyApplied(_ mutation: UniConnectImportMutation) async throws -> Bool {
        try await verifyMutation(mutation)
    }

    func finalizeVerified(_ mutation: UniConnectImportMutation) async throws {
        try finalizeMutation(mutation)
    }

    func persistDurably() async throws {
        try persist()
    }

    func verifyCommitted(_ mutations: [UniConnectImportMutation]) async throws -> Bool {
        let current = try readDocument()
        return mutations.allSatisfy { mutation in
            let source = UniConnectDocument(
                workspaces: [mutation.workspace],
                savedAt: Date(timeIntervalSince1970: 0)
            )
            let replanned = UniConnectImportPlanner().plan(
                importing: source,
                against: current
            )
            return replanned.rows.count == 1 && replanned.rows[0].outcome == .unchanged
        }
    }

    func rollback(to checkpointID: UUID, expectedStateToken: String?) async throws {
        let checkpoint = try await checkpoints.load(id: checkpointID)
        let current = try readStateBundle()
        let currentToken = try Self.stateToken(
            snapshot: current.snapshot,
            encryptedVault: current.encryptedVault
        )

        if let expectedStateToken,
           currentToken != expectedStateToken,
           let imported = stateBundlesByToken[expectedStateToken] {
            // A programmatic actor changed state while the import awaited remote
            // readiness. Apply a three-way inverse: only imported values that remain
            // untouched are reverted; independently changed fields and vault entries win.
            let merged = try UniConnectImportSnapshotMerger.reverting(
                imported: imported.snapshot,
                to: checkpoint.sessionSnapshot,
                preserving: current.snapshot
            )
            _ = try restoreVaultDelta(checkpoint.encryptedVault, imported.encryptedVault)
            try restoreSessionSnapshot(merged)
        } else {
            // Normal and crash-recovery paths have no concurrent writer. Restore
            // credentials first because SSH panels immediately consume their binding.
            try restoreVault(checkpoint.encryptedVault)
            try restoreSessionSnapshot(checkpoint.sessionSnapshot)
        }
        let restored = try readStateBundle()
        rollbackTargetTokensByCheckpointID[checkpointID] = try Self.stateToken(
            snapshot: restored.snapshot,
            encryptedVault: restored.encryptedVault
        )
    }

    func verifyRolledBack(to checkpointID: UUID) async throws -> Bool {
        let checkpoint = try await checkpoints.load(id: checkpointID)
        guard let target = rollbackTargetTokensByCheckpointID[checkpointID] else {
            return false
        }
        let current = try readStateBundle()
        let currentToken = try Self.stateToken(
            snapshot: current.snapshot,
            encryptedVault: current.encryptedVault
        )
        let checkpointToken = try Self.stateToken(
            snapshot: checkpoint.sessionSnapshot,
            encryptedVault: checkpoint.encryptedVault
        )
        if currentToken == checkpointToken {
            let restoredDocument = try readDocument()
            return currentToken == target
                && restoredDocument.workspaces == checkpoint.document.workspaces
                && verifyVault(checkpoint.encryptedVault)
        }
        return currentToken == target
    }

    private func readStateBundle() throws -> StateBundle {
        StateBundle(
            snapshot: try readStateSnapshot(),
            encryptedVault: try readVaultSnapshot()
        )
    }

    /// Hashes import-owned state while ignoring SSH PTY telemetry that changes as an
    /// attach child starts (title, tty, cwd/activity indicators). Those asynchronous
    /// updates are not concurrent user mutations and must not trigger import rollback.
    static func stateToken(
        snapshot: AppSessionSnapshot,
        encryptedVault: Data?
    ) throws -> String {
        var normalized = SessionPersistenceStore.sanitizedForPersistence(snapshot)
        normalized.createdAt = 0
        for windowIndex in normalized.windows.indices {
            for workspaceIndex in normalized.windows[windowIndex].tabManager.workspaces.indices {
                var workspace = normalized.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex]
                if workspace.uniConnect?.isSSH == true {
                    // The SSH/tmux binding lives in `uniConnect` and the terminal's
                    // `uniConnectTmuxSession`. Everything below is live PTY/UI telemetry.
                    workspace.uniConnect?.lastActivityAt = 0
                    workspace.processTitle = ""
                    workspace.isManuallyUnread = nil
                    workspace.hasUnreadIndicator = nil
                    workspace.notifications = nil
                    workspace.statusEntries = []
                    workspace.logEntries = []
                    workspace.progress = nil
                    workspace.gitBranch = nil
                    for panelIndex in workspace.panels.indices
                    where workspace.panels[panelIndex].type == .terminal {
                        workspace.panels[panelIndex].title = nil
                        workspace.panels[panelIndex].customTitle = normalizedSSHPanelTitle(
                            workspace.panels[panelIndex].customTitle
                        )
                        workspace.panels[panelIndex].directory = nil
                        workspace.panels[panelIndex].isManuallyUnread = false
                        workspace.panels[panelIndex].hasUnreadIndicator = nil
                        workspace.panels[panelIndex].restoredUnreadContributesToWorkspace = nil
                        workspace.panels[panelIndex].notifications = nil
                        workspace.panels[panelIndex].gitBranch = nil
                        workspace.panels[panelIndex].listeningPorts = []
                        workspace.panels[panelIndex].ttyName = nil
                        workspace.panels[panelIndex].terminal?.workingDirectory = nil
                        workspace.panels[panelIndex].terminal?.scrollback = nil
                        workspace.panels[panelIndex].terminal?.hibernation = nil
                        workspace.panels[panelIndex].terminal?.isRemoteTerminal = nil
                        workspace.panels[panelIndex].terminal?.remotePTYSessionID = nil
                        workspace.panels[panelIndex].terminal?.wasAgentRunning = nil
                    }
                } else {
                    for panelIndex in workspace.panels.indices {
                        workspace.panels[panelIndex].terminal?.scrollback = nil
                    }
                }
                normalized.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex] = workspace
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(normalized)
        data.append(0)
        if let encryptedVault {
            data.append(1)
            data.append(encryptedVault)
        } else {
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedSSHPanelTitle(_ title: String?) -> String? {
        let suffixes = [
            String(
                localized: "uniconnect.window.disconnectedSuffix",
                defaultValue: " · disconnected"
            ),
            " · disconnected",
            " · desconectada",
        ]
        return suffixes.reduce(title) { partial, suffix in
            guard let partial, partial.hasSuffix(suffix) else { return partial }
            return String(partial.dropLast(suffix.count))
        }
    }
}
