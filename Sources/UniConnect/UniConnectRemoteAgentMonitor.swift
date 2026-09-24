import CMUXAgentLaunch
import Foundation

/// Keeps the verified agent of every SSH window up to date by probing each box's tmux server.
///
/// One probe per box (vault credential) at a time, at most once a minute unless forced, and only
/// for boxes with at least one connected window. What each probe proves is applied per window with
/// the agent-tree.v1 rules: an agent with an id is recorded (a new id enters the history), a shell
/// keeps the last agent as history, and anything ambiguous, unidentified or unreachable changes
/// nothing stored. The live tmux ids (`$N`, `%N`) and an agent without id stay in memory for
/// Detalles and are never persisted.
@MainActor
final class UniConnectRemoteAgentMonitor {
    /// Live-only facts about one SSH window, never persisted.
    struct LiveWindow: Equatable {
        let tmuxSessionID: String?
        let paneID: String?
        let agent: AgentProbeReport.Agent?
        let cause: String?
        let hostUserID: Int?
        let checkedAt: Date
    }

    /// The socket SSH boxes attach to: tmux's default server.
    static let tmuxSocket = "default"

    private let probe: UniConnectRemoteAgentProbe
    private let minimumInterval: TimeInterval
    private var lastProbeByCredential: [UUID: Date] = [:]
    private var inFlight: Set<UUID> = []
    private(set) var liveByPanel: [UUID: LiveWindow] = [:]

    init(probe: UniConnectRemoteAgentProbe, minimumInterval: TimeInterval = 60) {
        self.probe = probe
        self.minimumInterval = minimumInterval
    }

    /// Probes every due box and applies what it proves.
    ///
    /// - Parameters:
    ///   - workspaces: Every open workspace of the app.
    ///   - force: Ignore the one-minute spacing («Guardar»); a box already in flight is still skipped.
    ///   - now: The reference time for the spacing.
    func refresh(workspaces: [Workspace], force: Bool, now: Date = Date()) async {
        var due: [(credential: UUID, workspaces: [Workspace])] = []
        for (credential, members) in Self.connectedBoxes(in: workspaces) {
            guard !inFlight.contains(credential) else { continue }
            if !force, let last = lastProbeByCredential[credential],
               now.timeIntervalSince(last) < minimumInterval {
                continue
            }
            inFlight.insert(credential)
            lastProbeByCredential[credential] = now
            due.append((credential, members))
        }
        guard !due.isEmpty else { return }
        let probe = self.probe
        let credentials = due.map { $0.credential }
        let reports = await withTaskGroup(of: (UUID, AgentProbeReport?).self) { group -> [UUID: AgentProbeReport] in
            for credential in credentials {
                group.addTask { (credential, await probe.probe(credentialID: credential)) }
            }
            var collected: [UUID: AgentProbeReport] = [:]
            for await (credential, report) in group {
                if let report { collected[credential] = report }
            }
            return collected
        }
        let appliedAt = Date()
        for entry in due {
            inFlight.remove(entry.credential)
            guard let report = reports[entry.credential] else { continue }
            for workspace in entry.workspaces {
                apply(report, to: workspace, at: appliedAt)
            }
        }
    }

    /// Reads one box right now for Detalles, without persisting anything.
    ///
    /// - Returns: The window's live facts, or `nil` when the box could not be read in time.
    func probeWindow(panelID: UUID, in workspace: Workspace, timeout: Duration) async -> LiveWindow? {
        guard let credential = workspace.uniConnectProfile?.credentialId,
              let tmuxName = workspace.uniConnectTmuxSessionsByPanelId[panelID],
              let report = await probe.probe(credentialID: credential, timeout: timeout),
              let session = report.session(named: tmuxName) else { return nil }
        let live = LiveWindow(
            tmuxSessionID: session.sessionID, paneID: session.paneID, agent: session.agent,
            cause: session.cause, hostUserID: report.uid, checkedAt: Date()
        )
        liveByPanel[panelID] = live
        return live
    }

    /// Applies one box report to the windows of one workspace.
    private func apply(_ report: AgentProbeReport, to workspace: Workspace, at date: Date) {
        guard report.error == nil, workspace.uniConnectProfile?.isSSH == true else { return }
        let timestamp = date.timeIntervalSince1970
        for (panelID, tmuxName) in workspace.uniConnectTmuxSessionsByPanelId {
            guard workspace.panels[panelID] is TerminalPanel,
                  let session = report.session(named: tmuxName) else { continue }
            liveByPanel[panelID] = LiveWindow(
                tmuxSessionID: session.sessionID, paneID: session.paneID, agent: session.agent,
                cause: session.cause, hostUserID: report.uid, checkedAt: date
            )
            let existing = workspace.uniConnectRemoteAgentsByPanelId[panelID]
            switch session.cause {
            case nil:
                guard let agent = session.agent, let sessionID = agent.sessionID, let source = agent.source else { continue }
                let observation = UniConnectRemoteAgentRecord.Observation(
                    provider: agent.provider,
                    sessionID: sessionID,
                    workingDirectory: agent.workingDirectory,
                    asRoot: agent.asRoot ?? report.uid.map { $0 == 0 },
                    source: source
                )
                if var record = existing, record.tmuxSocket == Self.tmuxSocket {
                    if record.observe(observation, at: timestamp) {
                        workspace.uniConnectSetRemoteAgent(record, panelId: panelID)
                    }
                } else if let record = UniConnectRemoteAgentRecord(
                    observing: observation, tmuxSocket: Self.tmuxSocket, at: timestamp
                ) {
                    workspace.uniConnectSetRemoteAgent(record, panelId: panelID)
                }
            case "sin_ia":
                // Back at a shell: the last agent stays as history and is not resumed by itself.
                guard var record = existing else { continue }
                if record.observeShell(at: timestamp) {
                    workspace.uniConnectSetRemoteAgent(record, panelId: panelID)
                }
            default:
                // sin_id or identidad_ambigua: nothing stored changes.
                continue
            }
        }
    }

    /// SSH boxes (by vault credential) with at least one connected tmux window.
    private static func connectedBoxes(in workspaces: [Workspace]) -> [UUID: [Workspace]] {
        var boxes: [UUID: [Workspace]] = [:]
        for workspace in workspaces {
            guard let profile = workspace.uniConnectProfile, profile.isSSH,
                  let credential = profile.credentialId,
                  workspace.uniConnectTmuxSessionsByPanelId.keys.contains(where: { panelID in
                      workspace.panels[panelID] is TerminalPanel
                          && !workspace.uniConnectDisconnectedPanelIds.contains(panelID)
                  }) else { continue }
            boxes[credential, default: []].append(workspace)
        }
        return boxes
    }
}
