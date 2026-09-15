import CMUXAgentLaunch
import Foundation

/// Turns a scope into the windows a relaunch would act on, and the ones it will not.
///
/// The Mac already knows more than a screen could tell it: every durable window keeps its tmux
/// binding and the conversations it has hosted, each with the agent it belongs to. So the inventory
/// is read from the model rather than scraped, and the screen is used later only to confirm.
///
/// What it will not do is fill in a gap. A window whose agent this build cannot close and verify, or
/// whose conversation is not known, comes back as an **exclusion with a reason** and is never quietly
/// dropped: a window missing from a list of 26 reads as a window that was forgotten.
@MainActor
struct UniConnectRelaunchInventory {
    /// A window that can be acted on, and everything needed to do it.
    struct Item {
        let target: UniConnectRelaunchExecutor.Target
    }

    /// The result of looking at a scope.
    struct Reading {
        var items: [Item] = []
        var exclusions: [RelaunchPlan.Exclusion] = []
    }

    private let machineID: String
    private let dialects: RelaunchDialects

    init(machineID: String, dialects: RelaunchDialects = .known) {
        self.machineID = machineID
        self.dialects = dialects
    }

    /// Reads every window of `workspaces`, keeping the ones this build can relaunch.
    func read(workspaces: [Workspace]) -> Reading {
        var reading = Reading()
        for workspace in workspaces {
            let boxName = workspace.customTitle ?? workspace.title

            // A box on a server is not a box with nothing in it. This build reaches tmux only
            // through a local command, so its windows are named and set aside, never dropped.
            if workspace.uniConnectProfile?.isSSH == true {
                reading.exclusions.append(contentsOf: remoteExclusions(of: workspace, boxName: boxName))
                continue
            }

            for (panelID, record) in workspace.uniConnectLocalWindowsByPanelId {
                let label = "\(boxName) · \(record.visibleName ?? "ventana")"

                // A window without tmux is a plain PTY: there is no session to reopen into, and
                // killing its process would take the work with it. Said out loud, for the same
                // reason as every other exclusion here.
                guard let binding = record.tmuxBinding else {
                    reading.exclusions.append(.init(label: label, cause: .unsupported))
                    continue
                }

                guard let conversation = activeConversation(of: record) else {
                    reading.exclusions.append(.init(label: label, cause: .ambiguousIdentity))
                    continue
                }
                let provider = conversation.kind.rawValue
                guard dialects.dialect(for: provider) != nil else {
                    // Knowing how an agent is spelled is not knowing how it lives.
                    reading.exclusions.append(.init(label: label, cause: .unsupported))
                    continue
                }

                let key = RelaunchTargetKey(
                    destination: .local(machineID: machineID),
                    tmuxServer: binding.socketName,
                    pane: binding.name,
                    generation: generation(of: record)
                )
                reading.items.append(.init(target: .init(
                    key: key,
                    label: label,
                    provider: provider,
                    socket: binding.socketName,
                    session: binding.name,
                    previousArgv: [],
                    evidence: RelaunchIdentityEvidence(
                        processID: 0,
                        pane: binding.name,
                        hook: .init(conversationID: conversation.sessionID, processID: 0, pane: binding.name)
                    )
                )))
                _ = panelID
            }
        }
        return reading
    }

    /// The windows of an SSH box, listed one by one with the reason this build cannot act on them.
    ///
    /// ``UniConnectRelaunchTmuxDriver`` runs `tmux` as a local command, and the session record of a
    /// remote window carries no conversation — only a session name. Both would have to change before
    /// a window on a server could be closed and verified, so the honest answer today is per window
    /// and out loud: a box that silently disappears from a list of boxes is the same bug as a window
    /// that silently disappears from a list of windows.
    private func remoteExclusions(of workspace: Workspace, boxName: String) -> [RelaunchPlan.Exclusion] {
        let host = workspace.uniConnectProfile?.hostLabel
        return workspace.uniConnectTmuxSessionsByPanelId
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { panelID, session in
                let name = workspace.panels[panelID]?.displayTitle ?? session
                let label = host.map { "\(boxName) · \(name) (\($0))" } ?? "\(boxName) · \(name)"
                return RelaunchPlan.Exclusion(label: label, cause: .unsupported)
            }
    }

    /// The conversation a window is on right now, preferring the active one over the latest seen.
    private func activeConversation(of record: UniConnectLocalWindowRecord) -> UniConnectLocalAgentConversation? {
        if let active = record.activeConversationID,
           let conversation = record.conversations.first(where: { $0.id == active }) {
            return conversation
        }
        // No active conversation means no agent is running: relaunching would start one that was
        // not there, which is not what "leave it as it was" means.
        return nil
    }

    /// A number that changes when this window's occupant does.
    ///
    /// Carried into the key so a plan drawn for one agent cannot act on the one that replaced it.
    private func generation(of record: UniConnectLocalWindowRecord) -> Int {
        Int(record.updatedAt.rounded())
    }
}
