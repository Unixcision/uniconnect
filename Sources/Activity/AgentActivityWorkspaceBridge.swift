import Foundation

/// Implementación de ``AgentActivityHostReading`` sobre los espacios del host.
///
/// Lee hooks, títulos, registros de ventana local y celdas de salida de cada panel de
/// terminal, y escribe el resultado en ``Workspace/applyAgentActivities(_:)``.
@MainActor
final class AgentActivityWorkspaceBridge: AgentActivityHostReading {
    private let workspacesProvider: @MainActor () -> [Workspace]

    /// - Parameter workspacesProvider: Espacios vivos de todas las ventanas de la app.
    init(workspacesProvider: @escaping @MainActor () -> [Workspace]) {
        self.workspacesProvider = workspacesProvider
    }

    func terminalInputs(now: TimeInterval) -> [AgentActivityTerminalInput] {
        var inputs: [AgentActivityTerminalInput] = []
        for workspace in uniqueWorkspaces() {
            for panel in workspace.panels.values {
                guard let terminal = panel as? TerminalPanel else { continue }
                inputs.append(Self.input(for: terminal, in: workspace))
            }
        }
        return inputs
    }

    func screenShowsPermissionPrompt(panelID: UUID) -> Bool {
        for workspace in uniqueWorkspaces() {
            guard let terminal = workspace.terminalPanel(for: panelID) else { continue }
            // El texto capturado muere aquí: solo el veredicto cruza al monitor.
            return AgentActivityScreenSignal(visibleText: terminal.surface.visibleText()).isWaitingForUser
        }
        return false
    }

    func apply(activitiesByWorkspace: [UUID: [UUID: AgentActivity]]) {
        for workspace in uniqueWorkspaces() {
            workspace.applyAgentActivities(activitiesByWorkspace[workspace.id] ?? [:])
        }
    }

    private func uniqueWorkspaces() -> [Workspace] {
        var seen: Set<UUID> = []
        return workspacesProvider().filter { seen.insert($0.id).inserted }
    }

    private static func input(for terminal: TerminalPanel, in workspace: Workspace) -> AgentActivityTerminalInput {
        let panelID = terminal.id
        let record = workspace.uniConnectLocalWindowsByPanelId[panelID]
        let tmux = record?.tmuxBinding.map {
            AgentActivityTerminalInput.TmuxTarget(socketName: $0.socketName, sessionName: $0.name)
        }
        let knownAgent = record?.runtimeState == .agent
            ? AgentActivity.Agent(restorableAgentKind: record?.activeConversation?.kind)
            : nil
        let evidence = AgentActivityEvidence(
            hooks: hooksEvidence(for: panelID, in: workspace),
            title: AgentActivityEvidence.Title(
                text: workspace.panelTitles[panelID] ?? terminal.title,
                currentCommand: terminal.surface.agentActivityForegroundCommand()
            ),
            knownAgent: knownAgent,
            output: AgentActivityEvidence.Output(
                lastOutputAt: terminal.surface.agentOutputActivity.snapshot().lastOutputAt
            )
        )
        return AgentActivityTerminalInput(
            workspaceID: workspace.id,
            panelID: panelID,
            tmux: tmux,
            evidence: evidence
        )
    }

    /// `set_agent_lifecycle` manda; sin él, el `set_status` más reciente del panel.
    private static func hooksEvidence(for panelID: UUID, in workspace: Workspace) -> AgentActivityEvidence.Hooks? {
        if let reportedAt = workspace.agentLifecycleReportedAt(panelId: panelID) {
            let keys = workspace.agentLifecycleStatesByPanelId[panelID]?.keys.sorted() ?? []
            return AgentActivityEvidence.Hooks(
                lifecycle: workspace.agentHibernationLifecycleState(panelId: panelID, fallback: nil),
                agent: keys.lazy.compactMap(AgentActivity.Agent.init(hookKey:)).first,
                reportedAt: reportedAt
            )
        }
        guard let entries = workspace.agentRuntimeState(forPanelId: panelID)?.statusEntries,
              let latest = entries.values.max(by: { $0.timestamp < $1.timestamp }) else {
            return nil
        }
        return AgentActivityEvidence.Hooks(
            lifecycle: AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: latest.value),
            agent: AgentActivity.Agent(hookKey: latest.key),
            reportedAt: latest.timestamp.timeIntervalSince1970
        )
    }
}
