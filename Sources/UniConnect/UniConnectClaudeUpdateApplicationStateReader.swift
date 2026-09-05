import Foundation

/// Reads live app models only long enough to create immutable updater snapshots.
@MainActor
final class UniConnectClaudeUpdateApplicationStateReader:
    UniConnectClaudeUpdateApplicationStateReading
{
    typealias TabManagersProvider = @MainActor @Sendable () -> [TabManager]

    private let tabManagersProvider: TabManagersProvider

    init(tabManagersProvider: @escaping TabManagersProvider) {
        self.tabManagersProvider = tabManagersProvider
    }

    func workspaceSnapshots() -> [UniConnectClaudeUpdateWorkspaceSnapshot] {
        tabManagersProvider().flatMap { manager in
            manager.tabs.compactMap(Self.snapshot(workspace:))
        }
    }

    func panelSnapshot(
        workspaceID: UUID,
        panelID: UUID
    ) -> UniConnectClaudeUpdatePanelSnapshot? {
        for manager in tabManagersProvider() {
            guard let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
                continue
            }
            return Self.panelSnapshot(panelID: panelID, workspace: workspace)
        }
        return nil
    }

    private static func snapshot(
        workspace: Workspace
    ) -> UniConnectClaudeUpdateWorkspaceSnapshot? {
        guard let profile = workspace.uniConnectProfile else { return nil }
        let panels = workspace.uniConnectOrderedTerminalPanelIds().compactMap { panelID in
            panelSnapshot(panelID: panelID, workspace: workspace)
        }
        return UniConnectClaudeUpdateWorkspaceSnapshot(
            id: workspace.id,
            boxID: workspace.id.uuidString.lowercased(),
            displayName: workspace.customTitle ?? workspace.title,
            kind: profile.kind,
            credentialID: profile.credentialId,
            hostLabel: profile.hostLabel,
            panels: panels
        )
    }

    private static func panelSnapshot(
        panelID: UUID,
        workspace: Workspace
    ) -> UniConnectClaudeUpdatePanelSnapshot? {
        guard let terminal = workspace.panels[panelID] as? TerminalPanel else { return nil }
        let panelDirectory = terminal.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceDirectory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = !panelDirectory.isEmpty
            ? panelDirectory
            : (!workspaceDirectory.isEmpty ? workspaceDirectory : nil)
        let displayName = workspace.panelCustomTitles[panelID]
            ?? workspace.panelTitles[panelID]
            ?? terminal.displayTitle

        return UniConnectClaudeUpdatePanelSnapshot(
            id: panelID,
            workspaceID: workspace.id,
            surfaceGeneration: terminal.surface.uniConnectSurfaceGeneration,
            displayName: displayName,
            directory: directory,
            persistedClaudeSessionID: workspace.uniConnectClaudeSessionsByPanelId[panelID],
            tmuxSession: workspace.uniConnectTmuxSessionsByPanelId[panelID],
            isDisconnected: workspace.uniConnectDisconnectedPanelIds.contains(panelID),
            lifecycle: workspace.agentLifecycleStatesByPanelId[panelID]?["claude_code"]?.rawValue,
            shellActivity: workspace.panelShellActivityStates[panelID]?.rawValue,
            restorableAgent: workspace.restoredAgentSnapshotsByPanelId[panelID]
        )
    }
}
