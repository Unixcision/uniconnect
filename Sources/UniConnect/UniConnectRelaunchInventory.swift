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
/// dropped: a window missing from a list of 26 reads as a window that was forgotten. The same applies
/// one level up — a box left out reads as a box with nothing in it — so a box on a server, which this
/// build cannot reach, is enumerated window by window rather than skipped.
@MainActor
struct UniConnectRelaunchInventory {
    /// A window that can be acted on, and everything needed to do it.
    struct Item {
        let target: UniConnectRelaunchExecutor.Target
    }

    /// The result of looking at a scope.
    struct Reading {
        var items: [Item] = []
        /// Every window set aside, with the panel it belongs to, so a single-window request can
        /// keep only its own exclusion by identity rather than by matching label text.
        var excluded: [UniConnectRelaunchCoordinator.ExcludedWindow] = []

        var exclusions: [RelaunchPlan.Exclusion] { excluded.map(\.exclusion) }
    }

    /// One window set aside, before its label has been made unique.
    private struct PendingExclusion {
        let panelID: UUID
        let name: String
        let cause: RelaunchCause
        /// The agent the window runs, when known, so the list says which one was left out.
        var agentName: String? = nil
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

            // A box on a server: this build reaches tmux only as a local command, so nothing here
            // can be closed or verified. Named window by window all the same.
            if workspace.uniConnectProfile?.isSSH == true {
                let host = workspace.uniConnectProfile?.hostLabel
                reading.excluded.append(contentsOf: labelled(
                    remoteWindows(of: workspace),
                    boxName: boxName,
                    host: host
                ))
                continue
            }

            var pending: [PendingExclusion] = []
            for (panelID, record) in workspace.uniConnectLocalWindowsByPanelId {
                let name = record.visibleName ?? "ventana"

                // A window without tmux is a plain PTY: there is no session to reopen into, and
                // killing its process would take the work with it.
                guard let binding = record.tmuxBinding else {
                    pending.append(.init(panelID: panelID, name: name, cause: .unsupported))
                    continue
                }

                guard let conversation = activeConversation(of: record) else {
                    // A window at its shell (or stopped) has no agent to relaunch: that is its own
                    // answer, not an identity that could not be established.
                    let cause: RelaunchCause = record.runtimeState == .agent ? .ambiguousIdentity : .noAgent
                    pending.append(.init(panelID: panelID, name: name, cause: cause))
                    continue
                }
                let provider = conversation.kind.rawValue
                guard dialects.dialect(for: provider) != nil else {
                    // Knowing how an agent is spelled is not knowing how it lives. Codex, agy and
                    // grok still come back when their window is reopened; they are only left out
                    // of a live close-and-reopen, and the list says which agent it was.
                    pending.append(.init(
                        panelID: panelID, name: name, cause: .unsupported,
                        agentName: conversation.displayName
                    ))
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
                    label: "\(boxName) · \(name)",
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
            }

            pending.append(contentsOf: unrecordedLocalWindows(of: workspace))
            reading.excluded.append(contentsOf: labelled(pending, boxName: boxName, host: nil))
        }
        return reading
    }

    /// Every terminal window of an SSH box, whether or not its tmux session has been recorded.
    ///
    /// Iterating the session map alone would drop a window whose binding has not been observed yet,
    /// which is the same silence one level down.
    private func remoteWindows(of workspace: Workspace) -> [PendingExclusion] {
        terminalPanels(of: workspace).map { panelID, panel in
            let session = workspace.uniConnectTmuxSessionsByPanelId[panelID]
            return .init(
                panelID: panelID,
                name: Self.windowName(of: panel, fallingBackTo: session),
                cause: .unsupported
            )
        }
    }

    /// Terminal windows of a local box that no record describes.
    ///
    /// Not the same as a window whose record says "shell": here there is no record at all, so what
    /// the window runs is genuinely unknown and ``RelaunchCause/ambiguousIdentity`` is the literal
    /// truth rather than a stand-in. An unrecorded window is the one most likely to be holding
    /// something nobody remembers starting, which is a reason to list it, not to hide it.
    private func unrecordedLocalWindows(of workspace: Workspace) -> [PendingExclusion] {
        terminalPanels(of: workspace)
            .filter { workspace.uniConnectLocalWindowsByPanelId[$0.0] == nil }
            .map { panelID, panel in
                .init(
                    panelID: panelID,
                    name: Self.windowName(of: panel, fallingBackTo: nil),
                    cause: .ambiguousIdentity
                )
            }
    }

    /// The box's terminal windows in a stable order, so two readings list them the same way.
    private func terminalPanels(of workspace: Workspace) -> [(UUID, any Panel)] {
        workspace.panels
            .filter { $0.value.panelType == .terminal }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { ($0.key, $0.value) }
    }

    /// Names every set-aside window, disambiguating only the ones that would otherwise collide.
    ///
    /// Tabs are routinely given the same name (`APP 1` beside another `APP 1`), and two identical
    /// lines in a list of exclusions cannot be told apart from one line and a dropped window. Where
    /// that happens the panel's short identifier is appended — and only there, because a suffix on
    /// every row is noise that makes the list harder to read, not easier.
    private func labelled(
        _ pending: [PendingExclusion],
        boxName: String,
        host: String?
    ) -> [UniConnectRelaunchCoordinator.ExcludedWindow] {
        let place = host.map { " (\($0))" } ?? ""
        var occurrences: [String: Int] = [:]
        for entry in pending { occurrences[entry.name, default: 0] += 1 }
        return pending.map { entry in
            let agent = entry.agentName.map { " — \($0)" } ?? ""
            let base = "\(boxName) · \(entry.name)\(place)\(agent)"
            let label = (occurrences[entry.name] ?? 0) > 1
                ? "\(base) [\(entry.panelID.uuidString.prefix(8).lowercased())]"
                : base
            return .init(panelID: entry.panelID, exclusion: RelaunchPlan.Exclusion(label: label, cause: entry.cause))
        }
    }

    /// What to call a window: its tab title, the tmux session behind it, or neither.
    private static func windowName(of panel: any Panel, fallingBackTo session: String?) -> String {
        let title = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let session, !session.isEmpty { return session }
        return "ventana"
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
