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
/// one level up — a box left out reads as a box with nothing in it.
///
/// SSH windows are not decided here: each one becomes a ``RemoteCandidate`` that the Linux worker
/// inspects on its destination, because only the destination can prove what runs in the pane.
@MainActor
struct UniConnectRelaunchInventory {
    /// A window that can be acted on, and everything needed to do it.
    struct Item {
        let target: UniConnectRelaunchExecutor.Target
    }

    /// An SSH window to be inspected by the worker on its box.
    struct RemoteCandidate: Sendable, Equatable {
        let panelID: UUID
        let label: String
        let credentialID: UUID
        let session: String
        let socket: String
        let provider: String
    }

    /// The result of looking at a scope.
    struct Reading {
        var items: [Item] = []
        /// SSH windows still to be inspected on their destination.
        var remote: [RemoteCandidate] = []
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

    /// The agents this Mac relaunches in SSH windows, through the Linux worker.
    ///
    /// Claude only until the others pass a live test from the Mac (`contracts/relaunch-v1/
    /// proveedores.json`): the worker knows Codex and Antigravity, but relaunching closes the agent.
    static let remoteProviders: Set<String> = ["claude"]

    private let machineID: String
    private let dialects: RelaunchDialects
    /// What the last probe saw in an SSH window: its provider, or `nil` when it saw no agent.
    private let remoteSighting: (UUID) -> RemoteSighting?

    /// What is known about the agent of an SSH window before asking its box.
    enum RemoteSighting: Equatable {
        /// An agent of this provider was seen running.
        case agent(provider: String)
        /// The window was seen at its shell.
        case shell
    }

    init(
        machineID: String,
        dialects: RelaunchDialects = .known,
        remoteSighting: @escaping (UUID) -> RemoteSighting? = { _ in nil }
    ) {
        self.machineID = machineID
        self.dialects = dialects
        self.remoteSighting = remoteSighting
    }

    /// Reads every window of `workspaces`, keeping the ones this build can relaunch.
    ///
    /// - Parameters:
    ///   - workspaces: The boxes in scope.
    ///   - verb: What will be done; ``RelaunchVerb/agentUpdate`` only takes Claude.
    ///   - onlyPanels: When set, only these windows are read (a window scope); nothing else is
    ///     inspected, so a single-window request never opens SSH to the rest of its box.
    func read(
        workspaces: [Workspace],
        verb: RelaunchVerb = .agentRelaunch,
        onlyPanels: Set<UUID>? = nil
    ) -> Reading {
        var reading = Reading()
        for workspace in workspaces {
            let boxName = workspace.customTitle ?? workspace.title
            if workspace.uniConnectProfile?.isSSH == true {
                let (candidates, pending) = remoteWindows(of: workspace, boxName: boxName, verb: verb, onlyPanels: onlyPanels)
                reading.remote.append(contentsOf: candidates)
                reading.excluded.append(contentsOf: labelled(pending, boxName: boxName, host: workspace.uniConnectProfile?.hostLabel))
                continue
            }

            var pending: [PendingExclusion] = []
            for (panelID, record) in workspace.uniConnectLocalWindowsByPanelId.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if let onlyPanels, !onlyPanels.contains(panelID) { continue }
                let name = record.visibleName ?? "ventana"

                // A window without tmux is a plain PTY: there is no session to reopen into, and
                // killing its process would take the work with it.
                guard let binding = record.tmuxBinding else {
                    pending.append(.init(panelID: panelID, name: name, cause: .noTmux))
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
                guard dialects.dialect(for: provider) != nil, verb != .agentUpdate || provider == "claude" else {
                    // Knowing how an agent is spelled is not knowing how it lives. Codex, agy and
                    // grok still come back when their window is reopened; they are only left out
                    // of a live close-and-reopen, and the list says which agent it was.
                    pending.append(.init(
                        panelID: panelID, name: name, cause: .providerUnsupported,
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
                    ),
                    panelID: panelID
                )))
            }

            pending.append(contentsOf: unrecordedLocalWindows(of: workspace, onlyPanels: onlyPanels))
            reading.excluded.append(contentsOf: labelled(pending, boxName: boxName, host: nil))
        }
        return reading
    }

    /// Every terminal window of an SSH box: a candidate for the worker, or an exclusion with cause.
    ///
    /// Iterating the session map alone would drop a window whose binding has not been observed yet,
    /// which is the same silence one level down.
    private func remoteWindows(
        of workspace: Workspace,
        boxName: String,
        verb: RelaunchVerb,
        onlyPanels: Set<UUID>?
    ) -> ([RemoteCandidate], [PendingExclusion]) {
        var candidates: [RemoteCandidate] = []
        var pending: [PendingExclusion] = []
        let names = terminalPanels(of: workspace).map { panelID, panel in
            (panelID, Self.windowName(of: panel, fallingBackTo: workspace.uniConnectTmuxSessionsByPanelId[panelID]))
        }
        let occurrences = Dictionary(names.map { ($0.1, 1) }, uniquingKeysWith: +)
        for (panelID, name) in names {
            if let onlyPanels, !onlyPanels.contains(panelID) { continue }
            guard let credentialID = workspace.uniConnectProfile?.credentialId else {
                pending.append(.init(panelID: panelID, name: name, cause: .noCredential))
                continue
            }
            guard let session = workspace.uniConnectTmuxSessionsByPanelId[panelID],
                  RelaunchWorkerRequest.isValidTmuxName(session) else {
                pending.append(.init(panelID: panelID, name: name, cause: .noTmux))
                continue
            }
            let sighting = remoteSighting(panelID) ?? workspace.uniConnectRemoteAgentsByPanelId[panelID].map { record in
                record.runtimeState == .agent ? .agent(provider: record.provider) : .shell
            }
            switch sighting {
            case .none:
                pending.append(.init(panelID: panelID, name: name, cause: .ambiguousIdentity))
            case .shell:
                pending.append(.init(panelID: panelID, name: name, cause: .noAgent))
            case let .agent(provider):
                let canonical = provider == "antigravity" ? "agy" : provider
                guard Self.remoteProviders.contains(canonical), verb != .agentUpdate || canonical == "claude" else {
                    pending.append(.init(panelID: panelID, name: name, cause: .providerUnsupported, agentName: canonical))
                    continue
                }
                let place = workspace.uniConnectProfile?.hostLabel.map { " (\($0))" } ?? ""
                let base = "\(boxName) · \(name)\(place)"
                let label = (occurrences[name] ?? 0) > 1
                    ? "\(base) [\(panelID.uuidString.prefix(8).lowercased())]"
                    : base
                let socket = workspace.uniConnectRemoteAgentsByPanelId[panelID]?.tmuxSocket
                    ?? UniConnectRemoteAgentMonitor.tmuxSocket
                guard RelaunchWorkerRequest.isValidTmuxName(socket) else {
                    pending.append(.init(panelID: panelID, name: name, cause: .noTmux))
                    continue
                }
                candidates.append(.init(
                    panelID: panelID, label: label, credentialID: credentialID,
                    session: session, socket: socket, provider: canonical
                ))
            }
        }
        return (candidates, pending)
    }

    /// Terminal windows of a local box that no record describes.
    ///
    /// Not the same as a window whose record says "shell": here there is no record at all, so what
    /// the window runs is genuinely unknown and ``RelaunchCause/ambiguousIdentity`` is the literal
    /// truth rather than a stand-in. An unrecorded window is the one most likely to be holding
    /// something nobody remembers starting, which is a reason to list it, not to hide it.
    private func unrecordedLocalWindows(of workspace: Workspace, onlyPanels: Set<UUID>?) -> [PendingExclusion] {
        terminalPanels(of: workspace)
            .filter { workspace.uniConnectLocalWindowsByPanelId[$0.0] == nil }
            .filter { onlyPanels?.contains($0.0) ?? true }
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
