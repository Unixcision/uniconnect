import AppKit
import CMUXAgentLaunch
import Foundation

/// «Detalles» of one window: the same value for the desktop modal and `mobile.terminal.details`.
///
/// Read-only end to end: it reads what is saved, then (optionally) confirms it live — one local
/// observation, or one probe of the SSH box bounded to 8 s — and never persists or launches
/// anything. When the live check fails it answers with what was saved and `host_inaccesible`.
/// The rules live in ``UniConnectWindowDetailsResolver``; this only gathers its inputs.
extension UniConnectCoordinator {
    /// Builds the details of one window, saved first and then checked live when `refresh` is set.
    ///
    /// - Returns: The details and whether the live check confirmed them, or `nil` when the window
    ///   is not a terminal of `workspace`.
    func windowDetails(
        panelID: UUID,
        in workspace: Workspace,
        refresh: Bool
    ) async -> (details: UniConnectWindowDetailsSnapshot, confirmed: Bool)? {
        guard let saved = savedWindowDetailsInput(panelID: panelID, in: workspace) else { return nil }
        let resolver = UniConnectWindowDetailsResolver(policy: try? AgentNoPromptPolicy())
        guard refresh else { return resolver.details(saved, check: .notChecked, now: Date()) }
        let check = await liveWindowCheck(saved: saved, panelID: panelID, in: workspace)
        return resolver.details(saved, check: check, now: Date())
    }

    /// Opens the «Detalles» modal at once with what is saved, and updates it with the live reading.
    func showWindowDetails(panelID: UUID, in workspace: Workspace) {
        guard Self.isEnabled, let input = savedWindowDetailsInput(panelID: panelID, in: workspace) else { return }
        let resolver = UniConnectWindowDetailsResolver(policy: try? AgentNoPromptPolicy())
        let saved = resolver.details(input, check: .notChecked, now: Date()).details
        let model = UniConnectWindowDetailsModel(snapshot: saved)
        let check = Task { @MainActor [weak self, weak workspace] in
            guard let self, let workspace else {
                model.finish(with: resolver.details(input, check: .failed, now: Date()).details, confirmed: false)
                return
            }
            let live = await self.liveWindowCheck(saved: input, panelID: panelID, in: workspace)
            guard !Task.isCancelled else { return }
            let result = resolver.details(input, check: live, now: Date())
            model.finish(with: result.details, confirmed: result.confirmed)
        }
        UniConnectSheet.present(
            on: NSApp.keyWindow ?? NSApp.mainWindow,
            size: CGSize(width: 580, height: 600)
        ) { dismiss in
            UniConnectWindowDetailsView(model: model, onClose: {
                check.cancel()
                dismiss()
            })
        }
    }

    /// What is saved about a window, before any live check.
    func savedWindowDetails(panelID: UUID, in workspace: Workspace, now: Date = Date()) -> UniConnectWindowDetailsSnapshot? {
        guard let input = savedWindowDetailsInput(panelID: panelID, in: workspace) else { return nil }
        return UniConnectWindowDetailsResolver(policy: try? AgentNoPromptPolicy())
            .details(input, check: .notChecked, now: now).details
    }

    /// Everything saved about a window, as the resolver's input.
    private func savedWindowDetailsInput(panelID: UUID, in workspace: Workspace) -> UniConnectWindowDetailsResolver.Saved? {
        guard workspace.panels[panelID] is TerminalPanel else { return nil }
        let profile = workspace.uniConnectProfile
        let isSSH = profile?.isSSH == true
        var host: UniConnectWindowDetailsSnapshot.Host?
        if isSSH, let credentialID = profile?.credentialId,
           let target = UniConnectVault.shared.credentialRecord(for: credentialID)?.effectiveTarget {
            // Only the effective endpoint travels: never the connect command, a password or the
            // credential id. With the vault closed there is no host, only the profile's label.
            host = .init(user: target.user, hostname: target.host, port: target.port)
        }
        let record = workspace.uniConnectLocalWindowsByPanelId[panelID]
        let remoteSession = workspace.uniConnectTmuxSessionsByPanelId[panelID]
        let windowName = workspace.panelCustomTitles[panelID]
            ?? record?.visibleName
            ?? workspace.panelTitles[panelID]
            ?? remoteSession
            ?? String(localized: "uniconnect.windowDetails.unnamedWindow", defaultValue: "Ventana")
        let socket: String?
        let session: String?
        let agent: UniConnectWindowDetailsResolver.SavedAgent?
        if isSSH {
            socket = remoteSession == nil ? nil : UniConnectRemoteAgentMonitor.tmuxSocket
            session = remoteSession
            agent = workspace.uniConnectRemoteAgentsByPanelId[panelID].flatMap(Self.savedAgent(remote:))
        } else {
            socket = record?.tmuxBinding?.socketName
            session = record?.tmuxBinding?.name
            agent = record.flatMap { savedAgent(local: $0, panelID: panelID, workspace: workspace) }
        }
        return UniConnectWindowDetailsResolver.Saved(
            workspaceID: workspace.id,
            terminalID: panelID,
            workspaceName: workspace.customTitle ?? workspace.title,
            kind: isSSH ? .ssh : .local,
            host: host,
            profileHostLabel: isSSH ? profile?.hostLabel : nil,
            windowName: windowName,
            tmuxSocket: socket,
            tmuxSession: session,
            agent: agent
        )
    }

    /// The last agent saved in an SSH window: the active one, or the last of its history.
    private static func savedAgent(remote: UniConnectRemoteAgentRecord) -> UniConnectWindowDetailsResolver.SavedAgent? {
        let observedAt = Date(timeIntervalSince1970: remote.observedAt)
        if let sessionID = remote.sessionID {
            return .init(
                provider: remote.provider, sessionID: sessionID, workingDirectory: remote.workingDirectory,
                asRoot: remote.asRoot, state: .saved, observedAt: observedAt
            )
        }
        guard let last = remote.history.last else { return nil }
        return .init(
            provider: last.provider, sessionID: last.sessionID, workingDirectory: last.workingDirectory,
            asRoot: remote.asRoot, state: .saved, observedAt: Date(timeIntervalSince1970: last.lastSeenAt)
        )
    }

    /// The last agent saved in a local window: the active one, the interrupted one, or the latest
    /// of its history even if the window is now at a shell.
    private func savedAgent(
        local record: UniConnectLocalWindowRecord,
        panelID: UUID,
        workspace: Workspace
    ) -> UniConnectWindowDetailsResolver.SavedAgent? {
        let seenLive = localAgentLastObservation(panelID: panelID, workspace: workspace)
        let conversation: UniConnectLocalAgentConversation
        let state: UniConnectWindowDetailsSnapshot.AgentState
        let observedAt: Date?
        if record.runtimeState == .agent, let active = record.activeConversation {
            conversation = active
            state = .saved
            observedAt = seenLive ?? Date(timeIntervalSince1970: record.updatedAt)
        } else if record.runtimeState == .stopped,
                  let interruptedID = record.interruptedConversationID,
                  let interrupted = record.conversations.first(where: { $0.id == interruptedID }) {
            conversation = interrupted
            state = .interrupted
            observedAt = seenLive ?? Date(timeIntervalSince1970: record.updatedAt)
        } else if let latest = record.latestConversation ?? record.conversations.last {
            conversation = latest
            state = .saved
            observedAt = nil
        } else {
            return nil
        }
        return .init(
            provider: conversation.kind == .antigravity ? "agy" : conversation.kind.rawValue,
            sessionID: conversation.sessionID,
            workingDirectory: conversation.resumeWorkingDirectory ?? record.workingDirectory,
            asRoot: false,
            state: state,
            observedAt: observedAt
        )
    }

    /// Reads the window live: one local observation, or one probe of its SSH box (≤ 8 s).
    private func liveWindowCheck(
        saved: UniConnectWindowDetailsResolver.Saved,
        panelID: UUID,
        in workspace: Workspace
    ) async -> UniConnectWindowDetailsResolver.LiveCheck {
        guard let session = saved.tmuxSession else { return .sessionNotRunning(checkedAt: Date()) }
        switch saved.kind {
        case .local:
            return await localWindowDetailsCheck(
                panelID: panelID, in: workspace, savedDirectory: saved.agent?.workingDirectory
            )
        case .ssh:
            // With the vault closed there is nothing to connect with: that is a failed check.
            guard saved.host != nil else { return .failed }
            let report = await probeRemoteAgentWindow(panelID: panelID, in: workspace)
            return UniConnectWindowDetailsResolver.remoteCheck(report: report, session: session, checkedAt: Date())
        }
    }
}
