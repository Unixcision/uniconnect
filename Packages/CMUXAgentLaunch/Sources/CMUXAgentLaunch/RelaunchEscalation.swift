import Foundation

/// The last step a relaunch needed to get an agent closed (`contracts/relaunch-v1`, 08-11-2026).
///
/// Reported per target as `escalation`. Each step is only taken when the one before it did not
/// work, and none of them is ever the tmux **server**.
public enum RelaunchEscalation: String, Sendable, Codable, CaseIterable {
    /// The agent left through its own clean exit (`/exit`).
    case exit
    /// SIGTERM, then SIGKILL, to the agent's process group; never the pane's shell.
    case killProcess = "kill_process"
    /// `respawn-pane -k` with an explicit login shell, then the resume command typed into it.
    case respawnPane = "respawn_pane"
    /// `kill-session` and a new session with the same name, socket and folder.
    case recreateSession = "recreate_session"
}
