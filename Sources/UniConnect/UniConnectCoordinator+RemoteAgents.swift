import CMUXAgentLaunch
import Foundation

/// SSH windows: which agent runs in each remote tmux session, kept by ``UniConnectRemoteAgentMonitor``.
extension UniConnectCoordinator {
    /// Receives the remote probe from the executable composition root.
    func configureRemoteAgentProbe(_ probe: UniConnectRemoteAgentProbe) {
        remoteAgentMonitor = UniConnectRemoteAgentMonitor(probe: probe)
    }

    /// Called from the 8 s autosave tick: probes the boxes that are due, in the background.
    ///
    /// A box is probed at most once a minute and never twice at the same time; the first tick
    /// after launch probes every connected box.
    func refreshRemoteAgentsIfDue(now: Date = Date()) {
        guard Self.isEnabled, let monitor = remoteAgentMonitor else { return }
        let workspaces = allTabManagers().flatMap(\.tabs)
        Task { @MainActor in
            await monitor.refresh(workspaces: workspaces, force: false, now: now)
        }
    }

    /// Probes every connected box now («Guardar»), waiting for the answers.
    ///
    /// Each probe is bounded by its own 10 s deadline, so this returns within about 10 s even
    /// when a box does not answer; what did not answer keeps its saved state.
    func refreshRemoteAgents(force: Bool) async {
        guard Self.isEnabled, let monitor = remoteAgentMonitor else { return }
        await monitor.refresh(workspaces: allTabManagers().flatMap(\.tabs), force: force)
    }

    /// The live facts of one SSH window from the last probe, or `nil`.
    func remoteAgentLiveWindow(panelID: UUID) -> UniConnectRemoteAgentMonitor.LiveWindow? {
        remoteAgentMonitor?.liveByPanel[panelID]
    }

    /// Reads one SSH window's box right now, for Detalles (nothing is persisted).
    ///
    /// - Returns: The box's report, or `nil` when it could not be read within `timeout`.
    func probeRemoteAgentWindow(
        panelID: UUID,
        in workspace: Workspace,
        timeout: Duration = .seconds(8)
    ) async -> AgentProbeReport? {
        guard Self.isEnabled, let monitor = remoteAgentMonitor else { return nil }
        return await monitor.probeWindow(panelID: panelID, in: workspace, timeout: timeout)
    }

    /// Whether a missing remote session of this SSH window may be recreated with its agent (D6).
    ///
    /// Restore and automatic reconnect ask this before handing a resume command to tmux; without a
    /// recent live sighting, or after a deliberate close, the window comes back as a shell.
    func remoteAgentResumeAllowed(panelID: UUID) -> Bool {
        remoteAgentMonitor?.resumeAllowed(panelID: panelID) ?? false
    }
}
