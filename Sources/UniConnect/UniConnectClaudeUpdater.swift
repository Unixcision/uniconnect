import Foundation
import AppKit

/// "Actualizar Claude": exit → `claude update` → resume, at three scopes (one window, one
/// box, or every open box). The tricky part is doing this safely on a remote tmux session
/// we do not control directly — see the per-kind functions below for the reasoning.
///
/// The update itself runs once per *host* even when several windows share it, so a box with
/// six tmux windows on the same server does not run `claude update` six times.
enum UniConnectClaudeUpdater {
    enum Scope {
        case window(UUID, Workspace)
        case box(Workspace)
        case all
    }

    // MARK: Entry point

    @MainActor
    static func run(_ scope: Scope) {
        guard UniConnectCoordinator.isEnabled else { return }
        let targets = collectTargets(for: scope)
        guard !targets.isEmpty else {
            presentInfo("No hay ninguna ventana con Claude Code en este ámbito.")
            return
        }
        let confirmed = confirm(targets, scope: scope)
        guard confirmed else { return }

        let byHost = Dictionary(grouping: targets, by: { $0.hostKey })
        let progress = UniConnectClaudeUpdateProgress(hostCount: byHost.count, windowCount: targets.count)
        progress.show()

        let queue = DispatchQueue(label: "uniconnect.claude-updater", qos: .userInitiated)
        queue.async {
            for (_, hostTargets) in byHost {
                updateHost(hostTargets, progress: progress)
            }
            DispatchQueue.main.async { progress.finish() }
        }
    }

    // MARK: Collecting affected windows

    /// One entry per local window bound to a Claude session, or per remote tmux window whose
    /// pane currently runs Claude. Panels the app cannot identify (no session, no tmux
    /// binding) are skipped: there is nothing safe to restart there.
    private struct Target {
        enum Kind {
            case local(panelId: UUID, workspace: Workspace, session: String, directory: String?)
            case remote(panelId: UUID, workspace: Workspace, tmuxSession: String, connect: String, hostLabel: String)
        }
        let kind: Kind
        /// Local targets group by "local"; remote targets group by connect command (one
        /// `claude update` per server, however many windows share it).
        var hostKey: String {
            switch kind {
            case .local: return "local"
            case .remote(_, _, _, let connect, _): return "ssh:" + connect
            }
        }
    }

    @MainActor
    private static func collectTargets(for scope: Scope) -> [Target] {
        switch scope {
        case .window(let panelId, let workspace):
            return target(panelId: panelId, in: workspace).map { [$0] } ?? []
        case .box(let workspace):
            return workspace.uniConnectOrderedTerminalPanelIds().compactMap { target(panelId: $0, in: workspace) }
        case .all:
            var targets: [Target] = []
            for tabManager in UniConnectCoordinator.shared.allTabManagers() {
                for workspace in tabManager.tabs {
                    targets.append(contentsOf: workspace.uniConnectOrderedTerminalPanelIds().compactMap {
                        target(panelId: $0, in: workspace)
                    })
                }
            }
            return targets
        }
    }

    @MainActor
    private static func target(panelId: UUID, in workspace: Workspace) -> Target? {
        guard let profile = workspace.uniConnectProfile else { return nil }
        switch profile.kind {
        case .local:
            guard let session = workspace.uniConnectClaudeSessionsByPanelId[panelId] else { return nil }
            let panelDirectory = (workspace.panels[panelId] as? TerminalPanel)?.directory
            let directory = (panelDirectory?.isEmpty == false ? panelDirectory : nil) ?? workspace.currentDirectory
            return Target(kind: .local(panelId: panelId, workspace: workspace, session: session, directory: directory))
        case .ssh:
            guard let tmuxSession = workspace.uniConnectTmuxSessionsByPanelId[panelId],
                  !workspace.uniConnectDisconnectedPanelIds.contains(panelId),
                  let credentialId = profile.credentialId,
                  let connect = UniConnectVault.shared.connectCommand(for: credentialId) else {
                return nil
            }
            return Target(kind: .remote(
                panelId: panelId,
                workspace: workspace,
                tmuxSession: tmuxSession,
                connect: connect,
                hostLabel: profile.hostLabel ?? UniConnectSSH.hostLabel(from: connect)
            ))
        }
    }

    // MARK: Confirmation

    @MainActor
    private static func confirm(_ targets: [Target], scope: Scope) -> Bool {
        // A single window is the fast, frequent path: no dialog, just do it.
        if case .window = scope { return true }
        let hosts = Set(targets.map(\.hostKey)).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Actualizar Claude en \(targets.count) ventana\(targets.count == 1 ? "" : "s") (\(hosts) servidor\(hosts == 1 ? "" : "es"))?"
        alert.informativeText = "Cada ventana con Claude Code sale de la sesión, se actualiza una vez por servidor, y solo si la actualización va bien se reanuda con --dangerously-skip-permissions. Si la actualización falla en un servidor, sus ventanas se reanudan igual, sin tocar nada más."
        alert.addButton(withTitle: "Actualizar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Local

    /// A local host is "updated" once even if it has several windows: exit every window
    /// first, run `claude update` a single time, then resume every window (or leave it on
    /// the old version if the update failed).
    private static func updateHost(_ targets: [Target], progress: UniConnectClaudeUpdateProgress) {
        guard let first = targets.first else { return }
        switch first.kind {
        case .local:
            updateLocalHost(targets, progress: progress)
        case .remote:
            updateRemoteHost(targets, progress: progress)
        }
    }

    private static func updateLocalHost(_ targets: [Target], progress: UniConnectClaudeUpdateProgress) {
        progress.log("Actualizando Claude en local…")
        let before = runShellCapturingOutput("claude --version 2>/dev/null || true")
        let updateOutput = runShellCapturingOutput("claude update 2>&1")
        let after = runShellCapturingOutput("claude --version 2>/dev/null || true")
        let ok = updateOutput.output.lowercased().contains("successfully updated")
            || updateOutput.output.lowercased().contains("up to date")
        appendLog(host: "local", before: before.output, after: after.output, updateOutput: updateOutput.output, ok: ok)

        DispatchQueue.main.async {
            for target in targets {
                guard case .local(let panelId, let workspace, let session, let directory) = target.kind else { continue }
                progress.tick(ok: ok)
                resumeLocalWindow(panelId: panelId, workspace: workspace, session: session, directory: directory)
            }
        }
    }

    /// Recreates the local window's terminal on the same panel, resuming the same Claude
    /// session — the same launcher the app uses when restoring a saved session, so the
    /// window behaves identically whether it comes from a restart or from this updater.
    @MainActor
    private static func resumeLocalWindow(panelId: UUID, workspace: Workspace, session: String, directory: String?) {
        guard let pane = workspace.paneId(forPanelId: panelId)
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else { return }
        let title = workspace.panelCustomTitles[panelId] ?? workspace.panelTitles[panelId]
        let commandLine = UniConnectSSH.claudeResumeCommandLine(session: session, directory: directory)
        guard let launcher = UniConnectSSH.writeLauncherScript(commandLine: commandLine, label: "claude-update-" + session.prefix(8)) else { return }
        workspace.uniConnectClaudeSessionsByPanelId.removeValue(forKey: panelId)
        _ = workspace.closePanel(panelId, force: true)
        guard let newPanel = workspace.newTerminalSurface(
            inPane: pane,
            focus: false,
            initialCommand: launcher,
            suppressWorkspaceRemoteStartupCommand: true
        ) else { return }
        workspace.uniConnectClaudeSessionsByPanelId[newPanel.id] = session
        if let title { workspace.setPanelCustomTitle(panelId: newPanel.id, title: title) }
    }

    // MARK: Remote (tmux over SSH)

    /// The remote side runs as one ssh script per host: check every affected pane really
    /// runs Claude (never send keys to anything else), exit each of them, update once,
    /// then resume every pane — `--continue` rather than a specific id, because a tmux
    /// window's Claude session id is never known to the app ahead of time.
    private static func updateRemoteHost(_ targets: [Target], progress: UniConnectClaudeUpdateProgress) {
        guard case .remote(_, _, _, let connect, let hostLabel) = targets.first!.kind else { return }
        progress.log("Actualizando Claude en \(hostLabel)…")
        let sessions = targets.compactMap { target -> String? in
            if case .remote(_, _, let tmuxSession, _, _) = target.kind { return tmuxSession }
            return nil
        }
        let script = Self.remoteScript(tmuxSessions: sessions)
        let client = UniConnectSSH.injectingOptions(["-T"] + UniConnectSSH.baseClientOptions, into: connect)
        let commandLine = client + " " + UniConnectSSH.shellQuote("sh -s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", commandLine]
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        var log: [String] = []
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log.append(String(decoding: data, as: UTF8.self))
        }
        guard (try? process.run()) != nil else {
            progress.log("✗ \(hostLabel): no se pudo conectar")
            DispatchQueue.main.async { for _ in targets { progress.tick(ok: false) } }
            return
        }
        stdin.fileHandleForWriting.write(Data((script + "\nexit\n").utf8))
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2)) }
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        let joined = log.joined()
        appendLog(host: hostLabel, before: "", after: "", updateOutput: joined, ok: joined.contains("UC_UPDATE_OK"))
        let ok = joined.contains("UC_UPDATE_OK")
        let failureMessage = ok ? nil : UniConnectCoordinator.humanizeSSHFailure(joined, log: log)

        DispatchQueue.main.async {
            for target in targets {
                guard case .remote(let panelId, let workspace, let tmuxSession, _, _) = target.kind else { continue }
                progress.tick(ok: ok, failure: failureMessage)
                workspace.uniConnectMarkDisconnected(panelId: panelId)
                UniConnectCoordinator.shared.reconnectNow(panelId: panelId, in: workspace, userInitiated: true)
            }
        }
    }

    /// POSIX shell piped over `ssh … 'sh -s'`. Every step is defensive: a pane not running
    /// Claude is left alone, and `claude --continue` (not a saved id, which we do not have
    /// for a tmux window) is what resumes the most recent conversation for that pane's cwd.
    private static func remoteScript(tmuxSessions: [String]) -> String {
        let quoted = tmuxSessions.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return """
        set -u
        SESSIONS="\(quoted)"
        command -v tmux >/dev/null 2>&1 || { echo "UC_UPDATE_FAIL no hay tmux"; exit 1; }
        command -v claude >/dev/null 2>&1 || { echo "UC_UPDATE_FAIL claude no está en el PATH"; exit 1; }

        RUNNING=""
        for s in $SESSIONS; do
          cmd=$(tmux display -p -t "$s" '#{pane_current_command}' 2>/dev/null) || continue
          case "$cmd" in
            claude|node) RUNNING="$RUNNING $s" ;;
          esac
        done
        if [ -z "$RUNNING" ]; then
          echo "UC_UPDATE_SKIP ninguna de las ventanas está ejecutando claude ahora mismo"
          exit 0
        fi

        for s in $RUNNING; do
          tmux send-keys -t "$s" C-c
          sleep 0.3
          tmux send-keys -t "$s" C-c
        done
        sleep 1
        for s in $RUNNING; do
          i=0
          while [ "$i" -lt 20 ]; do
            cmd=$(tmux display -p -t "$s" '#{pane_current_command}' 2>/dev/null) || break
            case "$cmd" in claude|node) ;; *) break ;; esac
            sleep 0.5; i=$((i + 1))
          done
        done

        echo "UC_UPDATE_BEFORE $(claude --version 2>/dev/null)"
        UPDATE_OUT=$(claude update 2>&1)
        echo "$UPDATE_OUT"
        echo "UC_UPDATE_AFTER $(claude --version 2>/dev/null)"
        case "$UPDATE_OUT" in
          *[Ss]uccessfully\\ updated*|*up\\ to\\ date*) echo "UC_UPDATE_OK" ;;
          *) echo "UC_UPDATE_FAIL la actualización no confirmó éxito"; exit 1 ;;
        esac

        for s in $RUNNING; do
          tmux send-keys -t "$s" 'claude --dangerously-skip-permissions --continue' Enter
        done
        """
    }

    // MARK: Small process/log helpers

    private static func runShellCapturingOutput(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func appendLog(host: String, before: String, after: String, updateOutput: String, ok: Bool) {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent(UniConnectPaths.directory.lastPathComponent).appendingPathComponent("logs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude-update.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n[\(stamp)] host=\(host) ok=\(ok)\n\(updateOutput)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private static func presentInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Actualizar Claude"
        alert.informativeText = message
        alert.addButton(withTitle: "Vale")
        alert.runModal()
    }
}

/// Tiny progress reporter: a non-blocking status item update plus a final summary alert.
/// Deliberately not a sheet — the user should be able to keep using the app while an
/// update spanning several servers runs in the background.
@MainActor
final class UniConnectClaudeUpdateProgress {
    private let hostCount: Int
    private let windowCount: Int
    private var updatedWindows = 0
    private var failures: [String] = []
    private var messages: [String] = []

    init(hostCount: Int, windowCount: Int) {
        self.hostCount = hostCount
        self.windowCount = windowCount
    }

    func show() {
        NSLog("[UniConnect] Actualizar Claude: %d ventana(s), %d servidor(es)", windowCount, hostCount)
    }

    nonisolated func log(_ message: String) {
        Task { @MainActor in
            self.messages.append(message)
            NSLog("[UniConnect] %@", message)
        }
    }

    func tick(ok: Bool, failure: String? = nil) {
        updatedWindows += 1
        if !ok, let failure { failures.append(failure) }
    }

    func finish() {
        let alert = NSAlert()
        alert.alertStyle = failures.isEmpty ? .informational : .warning
        alert.messageText = failures.isEmpty
            ? "Claude actualizado en \(windowCount) ventana\(windowCount == 1 ? "" : "s")"
            : "Actualizado con \(failures.count) fallo\(failures.count == 1 ? "" : "s")"
        var detail = messages.joined(separator: "\n")
        if !failures.isEmpty {
            detail += "\n\n" + Set(failures).sorted().joined(separator: "\n")
        }
        detail += "\n\nRegistro completo: Application Support/UniConnect/logs/claude-update.log"
        alert.informativeText = detail
        alert.addButton(withTitle: "Vale")
        alert.runModal()
    }
}
