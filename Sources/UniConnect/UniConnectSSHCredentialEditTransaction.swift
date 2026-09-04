import Foundation

/// Changes one SSH box to a fresh immutable credential revision after attach-only preflight.
@MainActor
struct UniConnectSSHCredentialEditTransaction {
    struct Window: Equatable, Hashable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
        let tmuxSession: String

    }

    enum Failure: Error, Equatable {
        case invalidConnection
        case duplicateTarget(UniConnectSSHTargetKey)
        case remoteSessionUnavailable(String)
        case credentialWriteFailed
        case commitFailed
        case persistenceFailed
        case rollbackFailed
        case cancelled
    }

    typealias ConflictResolver = @MainActor (
        Set<UniConnectSSHTargetKey>,
        Set<Window>
    ) -> UniConnectSSHTargetKey?
    typealias CredentialCreator = @MainActor (String) throws -> UUID
    typealias CredentialRemover = @MainActor (UUID) throws -> Void
    typealias RuntimeMutation = @MainActor (
        UUID,
        DetectedSSHSession,
        [Window]
    ) -> Bool
    typealias RuntimeRollback = @MainActor (UUID, [Window]) -> Bool
    typealias PersistenceCommit = @MainActor () throws -> Void

    private let executor: any UniConnectSSHCommandExecuting

    init(executor: any UniConnectSSHCommandExecuting) {
        self.executor = executor
    }

    /// Preflights every live tmux session, then switches and respawns in one main-actor phase.
    ///
    /// The old credential is intentionally never deleted. A failed commit restores every
    /// window through `rollback`, persists A again, then removes the unreferenced new revision.
    func execute(
        oldCredentialID: UUID,
        newConnectCommand: String,
        windows: [Window],
        conflictingTarget: ConflictResolver,
        createCredentialRevision: CredentialCreator,
        removeCredentialRevision: CredentialRemover,
        commit: RuntimeMutation,
        rollback: RuntimeRollback,
        persist: PersistenceCommit
    ) async throws -> UUID {
        guard let validated = UniConnectSSHConnectCommandValidator()
            .validatedCommand(newConnectCommand),
              let session = validated.detectedSession() else {
            throw Failure.invalidConnection
        }

        let orderedWindows = windows.sorted(by: Self.windowSort)
        let windowTargets = orderedWindows.compactMap {
            UniConnectSSHTargetKey(session: session, tmuxSession: $0.tmuxSession)
        }
        guard windowTargets.count == orderedWindows.count else {
            throw Failure.invalidConnection
        }
        var targets = Set<UniConnectSSHTargetKey>()
        for target in windowTargets where !targets.insert(target).inserted {
            throw Failure.duplicateTarget(target)
        }
        let editedOwners = Set(orderedWindows)
        if let conflict = conflictingTarget(targets, editedOwners) {
            throw Failure.duplicateTarget(conflict)
        }

        for tmuxSession in orderedWindows.map(\.tmuxSession).sorted() {
            guard let remoteCommand = UniConnectTmuxImportCommand
                .readOnlyExistenceCheck(session: tmuxSession),
                  let invocation = UniConnectSSHProcessInvocation(
                      session: session,
                      remoteCommand: remoteCommand
                  ) else {
                throw Failure.invalidConnection
            }
            do {
                try Task.checkCancellation()
                try await executor.execute(invocation, timeout: .seconds(12))
            } catch is CancellationError {
                throw Failure.cancelled
            } catch {
                throw Failure.remoteSessionUnavailable(tmuxSession)
            }
        }

        guard !Task.isCancelled else { throw Failure.cancelled }
        if let conflict = conflictingTarget(targets, editedOwners) {
            throw Failure.duplicateTarget(conflict)
        }

        let newCredentialID: UUID
        do {
            newCredentialID = try createCredentialRevision(newConnectCommand)
        } catch {
            throw Failure.credentialWriteFailed
        }

        let committed = commit(newCredentialID, session, orderedWindows)
        do {
            guard committed else { throw Failure.commitFailed }
            try persist()
            return newCredentialID
        } catch {
            let originalFailure = (error as? Failure) ?? .persistenceFailed
            let runtimeRestored = rollback(oldCredentialID, orderedWindows)
            let rollbackPersisted: Bool
            do {
                try persist()
                rollbackPersisted = true
            } catch {
                rollbackPersisted = false
            }
            let credentialRemoved: Bool
            if runtimeRestored, rollbackPersisted {
                do {
                    try removeCredentialRevision(newCredentialID)
                    credentialRemoved = true
                } catch {
                    credentialRemoved = false
                }
            } else {
                // B remains resolvable until both the in-memory rollback to A and its
                // durable session save succeed. A failed save may have left a B-bound
                // snapshot on disk even when the live panels already returned to A.
                credentialRemoved = false
            }
            guard runtimeRestored, credentialRemoved, rollbackPersisted else {
                throw Failure.rollbackFailed
            }
            throw originalFailure
        }
    }

    private static func windowSort(_ lhs: Window, _ rhs: Window) -> Bool {
        if lhs.workspaceID != rhs.workspaceID {
            return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
        }
        if lhs.tmuxSession != rhs.tmuxSession {
            return lhs.tmuxSession < rhs.tmuxSession
        }
        return lhs.panelID.uuidString < rhs.panelID.uuidString
    }
}
