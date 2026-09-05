import Foundation
import Bonsplit

/// Captures the destination of a user-requested terminal before its sheet is shown.
enum UniConnectNewWindowPlacement: Equatable {
    case tab(paneID: PaneID, afterTabID: TabID?)
    case split(sourcePanelID: UUID, orientation: SplitOrientation, insertFirst: Bool)

    @MainActor
    static func focusedPane(in workspace: Workspace) -> Self? {
        guard let pane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else { return nil }
        return .tab(paneID: pane, afterTabID: nil)
    }

    /// A closed or moved destination must not redirect a pending creation elsewhere.
    @MainActor
    func isAvailable(in workspace: Workspace) -> Bool {
        switch self {
        case .tab(let paneID, let afterTabID):
            guard workspace.bonsplitController.allPaneIds.contains(paneID) else { return false }
            return afterTabID.map { anchor in
                workspace.bonsplitController.tabs(inPane: paneID).contains { $0.id == anchor }
            } ?? true
        case .split(let sourcePanelID, _, _):
            return workspace.panels[sourcePanelID] != nil
                && workspace.paneId(forPanelId: sourcePanelID) != nil
        }
    }

    /// Creates only after confirmation, with the same stable panel ID used by persistence and SSH.
    @MainActor
    func createPanel(
        in workspace: Workspace,
        panelID: UUID,
        focus: Bool,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        suppressWorkspaceRemoteStartupCommand: Bool = false
    ) -> TerminalPanel? {
        guard isAvailable(in: workspace) else { return nil }
        workspace.clearSplitZoom()
        switch self {
        case .tab(let paneID, let afterTabID):
            let insertionIndex = afterTabID.flatMap { anchor in
                workspace.bonsplitController.tabs(inPane: paneID).firstIndex { $0.id == anchor }
            }.map { $0 + 1 }
            guard let panel = workspace.newTerminalSurface(
                panelID: panelID,
                inPane: paneID,
                focus: focus,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: tmuxStartCommand,
                initialInput: initialInput,
                suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand
            ) else { return nil }
            if let insertionIndex {
                _ = workspace.reorderSurface(panelId: panel.id, toIndex: insertionIndex, focus: focus)
            }
            return panel
        case .split(let sourcePanelID, let orientation, let insertFirst):
            return workspace.newTerminalSplit(
                from: sourcePanelID,
                orientation: orientation,
                insertFirst: insertFirst,
                focus: focus,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: tmuxStartCommand,
                newPanelID: panelID,
                initialInput: initialInput,
                suppressWorkspaceRemoteStartupCommand: suppressWorkspaceRemoteStartupCommand
            )
        }
    }
}
