import AppKit
import CMUXAgentLaunch
import Foundation

/// «Detalles» of one window: the same value for the desktop modal and `mobile.terminal.details`.
///
/// Read-only end to end: it reads what is saved, then (optionally) confirms it live — one local
/// observation, or one probe of the SSH box bounded to 8 s — and never persists or launches
/// anything. When the live check fails it answers with what was saved.
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
        guard let saved = savedWindowDetails(panelID: panelID, in: workspace) else { return nil }
        guard refresh else { return (saved, false) }
        return await liveWindowDetails(from: saved, panelID: panelID, in: workspace)
    }

    /// Opens the «Detalles» modal at once with what is saved, and updates it with the live reading.
    func showWindowDetails(panelID: UUID, in workspace: Workspace) {
        guard Self.isEnabled, let saved = savedWindowDetails(panelID: panelID, in: workspace) else { return }
        let model = UniConnectWindowDetailsModel(snapshot: saved)
        let check = Task { @MainActor [weak self, weak workspace] in
            guard let self, let workspace else {
                model.finish(with: saved, confirmed: false)
                return
            }
            let live = await self.liveWindowDetails(from: saved, panelID: panelID, in: workspace)
            guard !Task.isCancelled else { return }
            model.finish(with: live.details, confirmed: live.confirmed)
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
        guard workspace.panels[panelID] is TerminalPanel else { return nil }
        let profile = workspace.uniConnectProfile
        let isSSH = profile?.isSSH == true
        var host: UniConnectWindowDetailsSnapshot.Host?
        var hostLabel: String?
        if isSSH {
            // Only the effective endpoint travels: never the connect command, a password or the
            // credential id. With the vault closed, the profile's label is all there is.
            if let credentialID = profile?.credentialId,
               let target = UniConnectVault.shared.credentialRecord(for: credentialID)?.effectiveTarget {
                host = .init(user: target.user, hostname: target.host, port: target.port)
                hostLabel = "\(target.user)@\(target.host):\(target.port)"
            } else {
                hostLabel = profile?.hostLabel
            }
        }
        let record = workspace.uniConnectLocalWindowsByPanelId[panelID]
        let remoteSession = workspace.uniConnectTmuxSessionsByPanelId[panelID]
        let windowName = workspace.panelCustomTitles[panelID]
            ?? record?.visibleName
            ?? workspace.panelTitles[panelID]
            ?? remoteSession
            ?? String(localized: "uniconnect.windowDetails.unnamedWindow", defaultValue: "Ventana")
        let tmux: UniConnectWindowDetailsSnapshot.Tmux?
        if isSSH {
            tmux = remoteSession.map {
                .init(socket: UniConnectRemoteAgentMonitor.tmuxSocket, session: $0, sessionID: nil, paneID: nil, live: false)
            }
        } else {
            tmux = record?.tmuxBinding.map {
                .init(socket: $0.socketName, session: $0.name, sessionID: nil, paneID: nil, live: false)
            }
        }
        let policy = try? AgentNoPromptPolicy()
        var agent: UniConnectWindowDetailsSnapshot.Agent?
        if isSSH {
            if let remote = workspace.uniConnectRemoteAgentsByPanelId[panelID], remote.runtimeState == .agent {
                agent = Self.detailsAgent(
                    provider: remote.provider,
                    sessionID: remote.sessionID,
                    directory: remote.workingDirectory,
                    asRoot: remote.asRoot ?? (host?.user == "root"),
                    source: "registro",
                    state: .saved,
                    observedAt: Date(timeIntervalSince1970: remote.observedAt),
                    policy: policy
                )
            }
        } else if let record {
            let interrupted = record.interruptedConversationID.flatMap { id in
                record.conversations.first { $0.id == id }
            }
            if record.runtimeState == .agent, let active = record.activeConversation {
                agent = Self.detailsAgent(
                    conversation: active, fallbackDirectory: record.workingDirectory, state: .saved,
                    observedAt: Date(timeIntervalSince1970: record.updatedAt), policy: policy
                )
            } else if record.runtimeState == .stopped, let interrupted {
                agent = Self.detailsAgent(
                    conversation: interrupted, fallbackDirectory: record.workingDirectory, state: .interrupted,
                    observedAt: Date(timeIntervalSince1970: record.updatedAt), policy: policy
                )
            }
        }
        let reason: String? = tmux == nil ? "sin_tmux" : (agent == nil ? "sin_ia" : nil)
        return UniConnectWindowDetailsSnapshot(
            workspaceID: workspace.id,
            terminalID: panelID,
            checkedAt: now,
            workspaceName: workspace.customTitle ?? workspace.title,
            kind: isSSH ? .ssh : .local,
            host: host,
            hostLabel: hostLabel,
            windowName: windowName,
            tmux: tmux,
            agent: agent,
            reason: reason
        )
    }

    /// Confirms saved details against the live window: local observation or remote probe.
    private func liveWindowDetails(
        from saved: UniConnectWindowDetailsSnapshot,
        panelID: UUID,
        in workspace: Workspace
    ) async -> (details: UniConnectWindowDetailsSnapshot, confirmed: Bool) {
        var details = saved
        details.checkedAt = Date()
        guard saved.tmux != nil else { return (details, true) }
        let policy = try? AgentNoPromptPolicy()
        switch saved.kind {
        case .local:
            if let binding = workspace.uniConnectLocalWindowsByPanelId[panelID]?.tmuxBinding,
               let live = await localTmuxLiveIdentity(binding: binding) {
                details.tmux?.sessionID = live.sessionID
                details.tmux?.paneID = live.paneID
                details.tmux?.live = true
            }
            guard let state = await observeLocalWindow(panelID: panelID, in: workspace) else {
                return (details, false)
            }
            switch state {
            case .discovered(let observed):
                let kind = Self.restorableKind(forWire: observed.provider.rawValue)
                details.agent = Self.detailsAgent(
                    provider: observed.provider.rawValue,
                    displayName: kind?.displayName,
                    sessionID: observed.sessionID,
                    directory: observed.workingDirectory.map { AgentResumeWorkingDirectory().realPath($0) },
                    asRoot: observed.asRoot,
                    source: observed.source.rawValue,
                    state: .active,
                    observedAt: Date(),
                    policy: policy
                )
                details.reason = nil
            case .unidentified(let provider):
                details.agent = Self.detailsAgent(
                    provider: provider.rawValue,
                    displayName: Self.restorableKind(forWire: provider.rawValue)?.displayName,
                    sessionID: nil,
                    directory: saved.agent?.workingDirectory,
                    asRoot: false,
                    source: nil,
                    state: .active,
                    observedAt: Date(),
                    policy: policy
                )
                details.reason = "sin_id"
            case .ambiguous:
                details.agent = nil
                details.reason = "identidad_ambigua"
            case .shell:
                details.agent = nil
                details.reason = "sin_ia"
            case .agent:
                return (details, false)
            }
            return (details, true)
        case .ssh:
            guard let live = await probeRemoteAgentWindow(panelID: panelID, in: workspace) else {
                if details.agent == nil { details.reason = "host_inaccesible" }
                return (details, false)
            }
            details.tmux?.sessionID = live.tmuxSessionID
            details.tmux?.paneID = live.paneID
            details.tmux?.live = live.tmuxSessionID != nil
            let asRootFallback = live.hostUserID.map { $0 == 0 } ?? (saved.host?.user == "root")
            switch live.cause {
            case nil:
                guard let agent = live.agent, let sessionID = agent.sessionID else { return (details, false) }
                details.agent = Self.detailsAgent(
                    provider: agent.provider,
                    sessionID: sessionID,
                    directory: agent.workingDirectory,
                    asRoot: agent.asRoot ?? asRootFallback,
                    source: agent.source,
                    state: .active,
                    observedAt: live.checkedAt,
                    policy: policy
                )
                details.reason = nil
            case "sin_id":
                details.agent = live.agent.map { agent in
                    Self.detailsAgent(
                        provider: agent.provider,
                        sessionID: nil,
                        directory: agent.workingDirectory,
                        asRoot: agent.asRoot ?? asRootFallback,
                        source: nil,
                        state: .active,
                        observedAt: live.checkedAt,
                        policy: policy
                    )
                }
                details.reason = "sin_id"
            case "identidad_ambigua":
                details.agent = nil
                details.reason = "identidad_ambigua"
            default:
                details.agent = nil
                details.reason = "sin_ia"
            }
            return (details, true)
        }
    }

    /// The agent block for a saved local conversation.
    private static func detailsAgent(
        conversation: UniConnectLocalAgentConversation,
        fallbackDirectory: String,
        state: UniConnectWindowDetailsSnapshot.AgentState,
        observedAt: Date,
        policy: AgentNoPromptPolicy?
    ) -> UniConnectWindowDetailsSnapshot.Agent {
        detailsAgent(
            provider: conversation.kind == .antigravity ? "agy" : conversation.kind.rawValue,
            displayName: conversation.displayName,
            sessionID: conversation.sessionID,
            directory: conversation.resumeWorkingDirectory ?? fallbackDirectory,
            asRoot: false,
            source: "registro",
            state: state,
            observedAt: observedAt,
            policy: policy
        )
    }

    /// The agent block, with its derived no-prompt resume command when it has an id.
    private static func detailsAgent(
        provider: String,
        displayName: String? = nil,
        sessionID: String?,
        directory: String?,
        asRoot: Bool,
        source: String?,
        state: UniConnectWindowDetailsSnapshot.AgentState,
        observedAt: Date?,
        policy: AgentNoPromptPolicy?
    ) -> UniConnectWindowDetailsSnapshot.Agent {
        let wire = policy?.wireProvider(provider) ?? (provider == "antigravity" ? "agy" : provider)
        let resume = sessionID
            .flatMap { policy?.resume(provider: wire, sessionID: $0, asRoot: asRoot) }
            .map {
                UniConnectWindowDetailsSnapshot.Resume(
                    argv: $0.argv,
                    environment: $0.environment,
                    command: $0.shellLine(workingDirectory: directory),
                    noPromptVerified: $0.noPromptVerified
                )
            }
        return UniConnectWindowDetailsSnapshot.Agent(
            provider: wire,
            displayName: displayName ?? restorableKind(forWire: wire)?.displayName ?? wire,
            sessionID: sessionID,
            workingDirectory: directory,
            asRoot: asRoot,
            source: sessionID == nil ? nil : source,
            state: state,
            observedAt: observedAt,
            resume: resume
        )
    }

    private static func restorableKind(forWire provider: String) -> RestorableAgentKind? {
        RestorableAgentKind(rawValue: provider == "agy" ? "antigravity" : provider)
    }
}
