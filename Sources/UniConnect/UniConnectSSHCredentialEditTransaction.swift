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
    typealias CredentialCreator = @MainActor (
        String,
        UniConnectSSHEffectiveTarget
    ) throws -> UUID
    typealias CredentialRemover = @MainActor (UUID) throws -> Void
    typealias RuntimeMutation = @MainActor (
        UUID,
        UniConnectSSHEffectiveTarget,
        [Window]
    ) -> Bool
    typealias RuntimeRollback = @MainActor (UUID, [Window]) -> Bool
    typealias PersistenceCommit = @MainActor () throws -> Void

    private let executor: any UniConnectSSHCommandExecuting
    private let targetResolver: any UniConnectSSHTargetResolving

    init(
        executor: any UniConnectSSHCommandExecuting,
        targetResolver: any UniConnectSSHTargetResolving
    ) {
        self.executor = executor
        self.targetResolver = targetResolver
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
              let resolutionRequest = validated.targetResolutionRequest() else {
            throw Failure.invalidConnection
        }

        guard !Task.isCancelled else { throw Failure.cancelled }
        let resolution = await targetResolver.resolve(resolutionRequest)
        guard !Task.isCancelled else { throw Failure.cancelled }
        guard case .resolved(let effectiveTarget) = resolution else {
            throw Failure.invalidConnection
        }

        let orderedWindows = windows.sorted(by: Self.windowSort)
        let windowTargets = orderedWindows.compactMap {
            UniConnectSSHTargetKey(
                effectiveTarget: effectiveTarget,
                tmuxSession: $0.tmuxSession
            )
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
                  let validatedInvocation = validated.invocation(
                      injecting: Self.preflightOptions(
                          usesPasswordWrapper: validated.usesPasswordWrapper
                      ),
                      pinnedTo: effectiveTarget,
                      remoteCommand: remoteCommand
                  ),
                  let invocation = UniConnectSSHProcessInvocation(
                      executable: validatedInvocation.executable,
                      arguments: validatedInvocation.arguments,
                      environment: validatedInvocation.environment
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
            newCredentialID = try createCredentialRevision(
                newConnectCommand,
                effectiveTarget
            )
        } catch {
            throw Failure.credentialWriteFailed
        }

        let committed = commit(newCredentialID, effectiveTarget, orderedWindows)
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

    /// Keeps the edit preflight on the endpoint captured before any remote I/O.
    private static func preflightOptions(
        usesPasswordWrapper: Bool
    ) -> [String] {
        [
            "-T",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ForwardX11Trusted=no",
            "-o", "PermitLocalCommand=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", usesPasswordWrapper ? "BatchMode=no" : "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }
}
