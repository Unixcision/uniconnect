import Foundation
import Darwin
import UniConnectClaudeBridge

extension Workspace {
    struct DetachedAgentRuntimeState {
        let panelId: UUID
        let statusEntries: [String: SidebarStatusEntry]
        let agentPIDs: [String: pid_t]
        let agentPIDKeys: Set<String>
    }

    struct DetachedSurfaceTransfer {
        struct UniConnectSSHState {
            let profile: UniConnectWorkspaceProfile
            let credentialRecord: UniConnectSSHCredentialRecord
            let tmuxSession: String
            let claudeSession: String?
            let isDisconnected: Bool
            let bridgeStatus: ClaudeBridgeStatus?

            var credentialID: UUID? { profile.credentialId }

            var clonedWorkspaceProfile: UniConnectWorkspaceProfile {
                var result = profile
                let now = Date().timeIntervalSince1970
                result.importIdentity = UUID()
                result.createdAt = now
                result.lastActivityAt = now
                return result
            }
        }

        let sourceWorkspaceId: UUID
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let ttyName: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
        let restoredUnreadIndicator: RestoredPanelUnreadIndicator?
        let restorableAgent: SessionRestorableAgentSnapshot?
        let restorableAgentResumeState: RestoredAgentResumeState?
        let resumeBinding: SurfaceResumeBindingSnapshot?
        let uniConnectLocalWindow: UniConnectLocalWindowRecord?
        let requiresUniConnectLocalCompatibility: Bool
        let requiresUniConnectSSHCompatibility: Bool
        let uniConnectSSHState: UniConnectSSHState?
        let agentRuntime: DetachedAgentRuntimeState?
        let isRemoteTerminal: Bool
        let remoteRelayPort: Int?
        let remotePTYSessionID: String?
        let remoteCleanupConfiguration: WorkspaceRemoteConfiguration?

        func withRemoteCleanupConfiguration(_ configuration: WorkspaceRemoteConfiguration?) -> Self {
            Self(
                sourceWorkspaceId: sourceWorkspaceId,
                panelId: panelId,
                panel: panel,
                title: title,
                icon: icon,
                iconImageData: iconImageData,
                kind: kind,
                isLoading: isLoading,
                isPinned: isPinned,
                directory: directory,
                ttyName: ttyName,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                manuallyUnread: manuallyUnread,
                restoredUnreadIndicator: restoredUnreadIndicator,
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                resumeBinding: resumeBinding,
                uniConnectLocalWindow: uniConnectLocalWindow,
                requiresUniConnectLocalCompatibility: requiresUniConnectLocalCompatibility,
                requiresUniConnectSSHCompatibility: requiresUniConnectSSHCompatibility,
                uniConnectSSHState: uniConnectSSHState,
                agentRuntime: agentRuntime,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remotePTYSessionID: remotePTYSessionID,
                remoteCleanupConfiguration: configuration
            )
        }
    }

    /// Returns whether a panel can be detached into a newly cloned workspace.
    func canMoveSurfaceToNewUniConnectWorkspace(panelId: UUID) -> Bool {
        guard panels[panelId] != nil else { return false }
        if requiresUniConnectSSHCompatibility(panelId: panelId) {
            return detachedUniConnectSSHState(panelId: panelId) != nil
        }
        if requiresUniConnectLocalCompatibility(panelId: panelId) {
            return detachedUniConnectLocalWindow(panelId: panelId) != nil
        }
        return true
    }

    /// Applies the fail-closed cross-workspace policy before the source tab is detached.
    func canTransferSurface(panelId: UUID, to destination: Workspace) -> Bool {
        guard let panel = panels[panelId] else { return false }
        if destination.id == id { return true }

        if requiresUniConnectSSHCompatibility(panelId: panelId) {
            guard let state = detachedUniConnectSSHState(panelId: panelId) else {
                return false
            }
            return destination.acceptsUniConnectSSHState(state)
        }
        if requiresUniConnectLocalCompatibility(panelId: panelId) {
            guard let record = detachedUniConnectLocalWindow(panelId: panelId) else {
                return false
            }
            return destination.acceptsUniConnectLocalWindow(record)
        }

        // An unmanaged terminal has no durable box root to prove against a managed
        // destination. Non-terminal surfaces do not carry terminal trust state.
        return !(panel is TerminalPanel && destination.uniConnectProfile != nil)
    }

    /// Removes the source-side durable binding only after another workspace adopted it.
    func completeDetachedSurfaceTransfer(_ detached: DetachedSurfaceTransfer) {
        guard detached.sourceWorkspaceId == id,
              panels[detached.panelId] == nil else {
            return
        }

        var changed = false
        if detached.requiresUniConnectSSHCompatibility {
            changed = uniConnectTmuxSessionsByPanelId.removeValue(forKey: detached.panelId) != nil
                || changed
            changed = uniConnectClaudeSessionsByPanelId.removeValue(forKey: detached.panelId) != nil
                || changed
            changed = uniConnectDisconnectedPanelIds.remove(detached.panelId) != nil || changed
            changed = uniConnectClaudeBridgeStatusByPanelId.removeValue(forKey: detached.panelId) != nil
                || changed
        }
        if detached.uniConnectLocalWindow != nil {
            changed = uniConnectLocalWindowsByPanelId.removeValue(forKey: detached.panelId) != nil
                || changed
        }
        if changed, UniConnectCoordinator.isEnabled {
            UniConnectCoordinator.shared.requestSave()
        }
    }

    /// Returns whether this workspace may adopt a detached surface without changing
    /// its immutable SSH credential revision or creating a local terminal in an SSH box.
    func canAcceptUniConnectTransfer(_ detached: DetachedSurfaceTransfer) -> Bool {
        if detached.sourceWorkspaceId == id { return true }
        if detached.requiresUniConnectSSHCompatibility {
            guard let state = detached.uniConnectSSHState else { return false }
            return acceptsUniConnectSSHState(state)
        }
        if detached.requiresUniConnectLocalCompatibility || detached.uniConnectLocalWindow != nil {
            guard let record = detached.uniConnectLocalWindow else { return false }
            return acceptsUniConnectLocalWindow(record)
        }
        return !(detached.panel is TerminalPanel && uniConnectProfile != nil)
    }

    /// Adopts durable UniConnect state after the destination tab has been created.
    func adoptUniConnectState(from detached: DetachedSurfaceTransfer) {
        guard let state = detached.uniConnectSSHState else { return }

        uniConnectTmuxSessionsByPanelId[detached.panelId] = state.tmuxSession
        if let claudeSession = state.claudeSession {
            uniConnectClaudeSessionsByPanelId[detached.panelId] = claudeSession
        } else {
            uniConnectClaudeSessionsByPanelId.removeValue(forKey: detached.panelId)
        }
        if state.isDisconnected {
            uniConnectDisconnectedPanelIds.insert(detached.panelId)
        } else {
            uniConnectDisconnectedPanelIds.remove(detached.panelId)
        }
        if let bridgeStatus = state.bridgeStatus {
            uniConnectClaudeBridgeStatusByPanelId[detached.panelId] = bridgeStatus
        } else {
            uniConnectClaudeBridgeStatusByPanelId.removeValue(forKey: detached.panelId)
        }
        uniConnectProfile?.touch()
        UniConnectCoordinator.shared.rebindClaudeBridgeRoute(detached.panelId, to: self)
    }

    func requiresUniConnectSSHCompatibility(panelId: UUID) -> Bool {
        uniConnectTmuxSessionsByPanelId[panelId] != nil
            || (uniConnectProfile?.isSSH == true && panels[panelId] is TerminalPanel)
    }

    func requiresUniConnectLocalCompatibility(panelId: UUID) -> Bool {
        uniConnectProfile?.isSSH == false && panels[panelId] is TerminalPanel
    }

    func detachedUniConnectLocalWindow(panelId: UUID) -> UniConnectLocalWindowRecord? {
        guard requiresUniConnectLocalCompatibility(panelId: panelId),
              let boxRoot = uniConnectLocalBoxRoot,
              let record = uniConnectLocalWindowsByPanelId[panelId],
              record.boxRoot == boxRoot,
              UniConnectLocalWindowRecord.validatedWorkingDirectory(
                  record.workingDirectory,
                  within: boxRoot
              ) == record.workingDirectory else {
            return nil
        }
        return record
    }

    func detachedUniConnectSSHState(
        panelId: UUID
    ) -> DetachedSurfaceTransfer.UniConnectSSHState? {
        guard requiresUniConnectSSHCompatibility(panelId: panelId),
              let profile = uniConnectProfile,
              profile.isSSH,
              let credentialID = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialID),
              credentialRecord.effectiveTarget != nil,
              let tmuxSession = uniConnectTmuxSessionsByPanelId[panelId],
              !tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DetachedSurfaceTransfer.UniConnectSSHState(
            profile: profile,
            credentialRecord: credentialRecord,
            tmuxSession: tmuxSession,
            claudeSession: uniConnectClaudeSessionsByPanelId[panelId],
            isDisconnected: uniConnectDisconnectedPanelIds.contains(panelId),
            bridgeStatus: uniConnectClaudeBridgeStatusByPanelId[panelId]
        )
    }

    private func acceptsUniConnectSSHState(
        _ state: DetachedSurfaceTransfer.UniConnectSSHState
    ) -> Bool {
        guard let sourceCredentialID = state.credentialID,
              let profile = uniConnectProfile,
              profile.isSSH,
              profile.credentialId == sourceCredentialID,
              let sourceTarget = state.credentialRecord.effectiveTarget,
              let destinationRecord = UniConnectVault.shared.credentialRecord(
                  for: sourceCredentialID
              ),
              destinationRecord == state.credentialRecord,
              destinationRecord.effectiveTarget == sourceTarget,
              !uniConnectTmuxSessionsByPanelId.contains(where: { panelID, session in
                  panels[panelID] != nil
                      && UniConnectSSH.sanitizedTmuxName(session)
                          == UniConnectSSH.sanitizedTmuxName(state.tmuxSession)
              }) else {
            return false
        }
        return true
    }

    private func acceptsUniConnectLocalWindow(_ record: UniConnectLocalWindowRecord) -> Bool {
        guard let profile = uniConnectProfile,
              !profile.isSSH,
              let destinationRoot = uniConnectLocalBoxRoot,
              record.boxRoot == destinationRoot,
              UniConnectLocalWindowRecord.validatedWorkingDirectory(
                  record.workingDirectory,
                  within: destinationRoot
              ) == record.workingDirectory else {
            return false
        }
        return true
    }
}
