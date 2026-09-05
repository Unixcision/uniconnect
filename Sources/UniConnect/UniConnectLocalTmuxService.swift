import CmuxProcess
import Foundation

/// Performs bounded, read-only tmux inspection away from the main actor.
actor UniConnectLocalTmuxService: UniConnectLocalTmuxInspecting {
    private let commands: any CommandRunning
    private let processEnvironment: @Sendable (Int) -> [String: String]?

    init(
        commands: any CommandRunning,
        processEnvironment: @escaping @Sendable (Int) -> [String: String]?
    ) {
        self.commands = commands
        self.processEnvironment = processEnvironment
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
}
