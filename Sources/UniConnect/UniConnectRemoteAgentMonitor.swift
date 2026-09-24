import CMUXAgentLaunch
import Foundation

/// Keeps the verified agent of every SSH window up to date by probing each box's tmux server.
///
/// One probe per box (vault credential) at a time, at most once a minute unless forced, and only
/// for boxes with at least one connected window. What each probe proves is applied per window with
/// the agent-tree.v1 rules (`contracts/agent-tree-v1/sonda-lectura.json`): an agent with an id is
/// recorded (a new id enters the history), `sin_ia` of a **live** pane keeps the last agent as
/// history, and anything ambiguous, unidentified, dead (`panel_muerto`) or unreachable changes
/// nothing stored. The live tmux ids (`$N`, `%N`) and an agent without id stay in memory for
/// Detalles and are never persisted.
///
/// It also remembers, in memory only, when a live reading last saw each window's session and
/// whether a whole-socket reading showed it missing while the server lived on with other sessions
/// (a deliberate close). Both decide whether a missing session may be recreated **with its agent**
/// (D6, ``resumeAllowed(panelID:now:)``).
@MainActor
final class UniConnectRemoteAgentMonitor {
    /// Live-only facts about one SSH window, never persisted.
    struct LiveWindow: Equatable {
        let tmuxSessionID: String?
        let paneID: String?
        let agent: AgentProbeReport.Agent?
        /// The probe's `reason`: `nil`, `sin_id`, `sin_ia`, `identidad_ambigua` or `panel_muerto`.
        let reason: String?
        /// What a reader may do with this reading.
        let effect: AgentProbeReport.Effect
        let hostUserID: Int?
        let checkedAt: Date
    }

    /// The socket SSH boxes attach to: tmux's default server.
    static let tmuxSocket = "default"

    /// How recent the last live sighting of a session must be for it to be recreated with its
    /// agent: two ticks of the one-minute SSH probe (D6).
    static let resumeWindow: TimeInterval = 120

    private let probe: UniConnectRemoteAgentProbe
    private let minimumInterval: TimeInterval
    private var lastProbeByCredential: [UUID: Date] = [:]
    private var inFlight: Set<UUID> = []
    private(set) var liveByPanel: [UUID: LiveWindow] = [:]
    /// When a live reading last saw each window's session.
    private var lastSeenByPanel: [UUID: Date] = [:]
    /// Windows whose session a whole-socket reading showed missing while the server lived on with
    /// other sessions: somebody closed it on purpose (`missing_is_deliberate`).
    private var deliberatelyClosed: Set<UUID> = []

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
        forgetClosedWindows(workspaces: workspaces)
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
    /// A sighting of the window's session is remembered in memory (Detalles and D6); nothing
    /// stored changes.
    ///
    /// - Returns: The box's report, or `nil` when it could not be read in time.
    func probeWindow(panelID: UUID, in workspace: Workspace, timeout: Duration) async -> AgentProbeReport? {
        guard let credential = workspace.uniConnectProfile?.credentialId,
              let tmuxName = workspace.uniConnectTmuxSessionsByPanelId[panelID],
              let report = await probe.probe(credentialID: credential, timeout: timeout) else { return nil }
        if let session = report.session(named: tmuxName) {
            let checkedAt = Date()
            liveByPanel[panelID] = Self.liveWindow(session, report: report, at: checkedAt)
            lastSeenByPanel[panelID] = checkedAt
            deliberatelyClosed.remove(panelID)
        }
        return report
    }

    /// Whether a missing remote session of this window may be recreated **with its agent** (D6).
    ///
    /// Only when a live reading saw the session at most two ticks ago (≤ 120 s) and no complete
    /// reading showed it missing while the server lived on with other sessions. At launch nothing
    /// has been seen yet, so a restore reattaches (or opens a shell) without resuming the agent;
    /// the VPS supervisor recreates what is in its manifest.
    ///
    /// - Parameters:
    ///   - panelID: The SSH window.
    ///   - now: The reference time.
    func resumeAllowed(panelID: UUID, now: Date = Date()) -> Bool {
        guard !deliberatelyClosed.contains(panelID), let seen = lastSeenByPanel[panelID] else { return false }
        let age = now.timeIntervalSince(seen)
        return age >= 0 && age <= Self.resumeWindow
    }

    /// Applies one box report to the windows of one workspace.
    private func apply(_ report: AgentProbeReport, to workspace: Workspace, at date: Date) {
        guard report.error == nil, workspace.uniConnectProfile?.isSSH == true else { return }
        let timestamp = date.timeIntervalSince1970
        for (panelID, tmuxName) in workspace.uniConnectTmuxSessionsByPanelId {
            guard workspace.panels[panelID] is TerminalPanel else { continue }
            guard let session = report.session(named: tmuxName) else {
                // A complete reading of the whole socket (the monitor never passes --session): the
                // server lives on with other sessions and this one is missing, so it was closed on
                // purpose. A server that is gone says nothing about intent.
                if report.missingMeansGone, report.server, !report.sessions.isEmpty {
                    deliberatelyClosed.insert(panelID)
                }
                continue
            }
            let live = Self.liveWindow(session, report: report, at: date)
            liveByPanel[panelID] = live
            lastSeenByPanel[panelID] = date
            deliberatelyClosed.remove(panelID)
            let existing = workspace.uniConnectRemoteAgentsByPanelId[panelID]
            switch live.effect {
            case .agent:
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
            case .shell:
                // Back at a shell in a live pane: the last agent stays as history and is not
                // resumed by itself. The only reading that leads here.
                guard var record = existing else { continue }
                if record.observeShell(at: timestamp) {
                    workspace.uniConnectSetRemoteAgent(record, panelId: panelID)
                }
            case .unidentified, .nothing:
                // sin_id, identidad_ambigua, panel_muerto or not live: nothing stored changes.
                continue
            }
        }
    }

    private static func liveWindow(_ session: AgentProbeReport.Session, report: AgentProbeReport, at date: Date) -> LiveWindow {
        LiveWindow(
            tmuxSessionID: session.sessionID, paneID: session.paneID, agent: session.agent,
            reason: session.reason, effect: session.effect, hostUserID: report.uid, checkedAt: date
        )
    }

    /// Drops the in-memory facts of windows that no longer exist.
    private func forgetClosedWindows(workspaces: [Workspace]) {
        var open: Set<UUID> = []
        for workspace in workspaces {
            open.formUnion(workspace.uniConnectTmuxSessionsByPanelId.keys)
        }
        liveByPanel = liveByPanel.filter { open.contains($0.key) }
        lastSeenByPanel = lastSeenByPanel.filter { open.contains($0.key) }
        deliberatelyClosed.formIntersection(open)
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
