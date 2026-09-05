import CmuxProcess
import CmuxControlSocket
import Foundation

/// Performs bounded, read-only tmux inspection away from the main actor.
actor UniConnectLocalTmuxService: UniConnectLocalTmuxInspecting {
    private let commands: any CommandRunning
    private let processEnvironment: @Sendable (Int) -> [String: String]?
    private let processIdentity: @Sendable (Int) -> UniConnectLocalTmuxProcessIdentity?
    private let isProcessDescendant: @Sendable (Int, Int) -> Bool

    init(
        commands: any CommandRunning,
        processEnvironment: @escaping @Sendable (Int) -> [String: String]?,
        processIdentity: @escaping @Sendable (Int) -> UniConnectLocalTmuxProcessIdentity? = {
            UniConnectLocalTmuxProcessIdentity(processID: $0)
        },
        isProcessDescendant: @escaping @Sendable (Int, Int) -> Bool = {
            guard let peer = pid_t(exactly: $0), let ancestor = pid_t(exactly: $1) else { return false }
            return SocketTransport().isProcessDescendant(peer, of: ancestor)
        }
    ) {
        self.commands = commands
        self.processEnvironment = processEnvironment
        self.processIdentity = processIdentity
        self.isProcessDescendant = isProcessDescendant
    }

    func generation(
        for binding: UniConnectLocalTmuxBinding,
        workspaceID: UUID,
        panelID: UUID
    ) async -> UUID? {
        let arguments = [
            "-L", binding.socketName, "display-message", "-p", "-t", "=" + binding.name + ":",
            "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}",
        ]
        guard let before = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ) else { return nil }
        let fields = before.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0].hasPrefix("$"), fields[1].hasPrefix("%"),
              fields[3] == "0", let pid = Int(fields[2]), pid > 1,
              let environment = processEnvironment(pid),
              UUID(uuidString: environment["CMUX_WORKSPACE_ID"] ?? "") == workspaceID,
              UUID(uuidString: environment["CMUX_SURFACE_ID"] ?? "") == panelID,
              let generation = UUID(uuidString: environment["UNICONNECT_SURFACE_GENERATION"] ?? "") else {
            return nil
        }
        // Neither a recycled PID nor a pane replaced during the environment read may grant
        // an old generation permission to mutate the newly attached terminal.
        guard let after = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), after == before,
              processEnvironment(pid)?["UNICONNECT_SURFACE_GENERATION"] == environment["UNICONNECT_SURFACE_GENERATION"] else {
            return nil
        }
        return generation
    }

    func verifiedOwner(
        of peer: UniConnectLocalTmuxProcessIdentity,
        among owners: [UniConnectLocalTmuxOwner]
    ) async -> UniConnectLocalTmuxOwner? {
        guard !Task.isCancelled, processIdentity(peer.pid) == peer,
              let peerEnvironment = processEnvironment(peer.pid),
              let workspaceID = UUID(uuidString: peerEnvironment["CMUX_WORKSPACE_ID"] ?? ""),
              let panelID = UUID(uuidString: peerEnvironment["CMUX_SURFACE_ID"] ?? "") else { return nil }
        // Environment is only an index into app-owned bindings, never an authorization claim.
        let candidates = owners.filter { $0.workspaceID == workspaceID && $0.panelID == panelID }
        guard candidates.count == 1, let owner = candidates.first else { return nil }
        let arguments = [
            "-L", owner.binding.socketName, "display-message", "-p", "-t", "=" + owner.binding.name + ":",
            "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{session_name}",
        ]
        guard let before = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), before.utf8.count <= 1_024 else { return nil }
        let fields = before.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0].hasPrefix("$"), fields[1].hasPrefix("%"),
              fields[3] == "0", fields[4] == owner.binding.name,
              let panePID = Int(fields[2]), panePID > 1,
              let paneIdentity = processIdentity(panePID), paneIdentity.userID == peer.userID,
              let paneEnvironment = processEnvironment(panePID),
              UUID(uuidString: paneEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: paneEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let paneGeneration = UUID(uuidString: paneEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? ""),
              processIdentity(peer.pid) == peer,
              isProcessDescendant(peer.pid, panePID) else { return nil }
        // The pane's original generation may predate a reattached Ghostty surface. Verify
        // that it is stable, not equal to the new surface generation in the model snapshot.
        guard let after = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), after == before, !Task.isCancelled,
              processIdentity(panePID) == paneIdentity,
              processIdentity(peer.pid) == peer,
              let finalEnvironment = processEnvironment(panePID),
              UUID(uuidString: finalEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: finalEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              UUID(uuidString: finalEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? "") == paneGeneration,
              isProcessDescendant(peer.pid, panePID) else { return nil }
        return owner
    }
}
