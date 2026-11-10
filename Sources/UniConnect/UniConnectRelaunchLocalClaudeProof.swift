import CMUXAgentLaunch
import Foundation

/// What the plan proved about a local Claude, checked again before anything is closed.
struct UniConnectRelaunchLocalClaudeProof: Sendable, Equatable {
    /// The tmux pane (`%13`).
    let pane: String
    /// The pane's own shell, which is never signalled.
    let shell: UniConnectRelaunchProcessInfo
    /// The Claude process.
    let agent: UniConnectRelaunchProcessInfo
    /// Its real argv.
    let argv: [String]
    /// Whether `IS_SANDBOX=1` was in its environment (it only comes back if it was).
    let sandboxed: Bool
    /// The folder the conversation runs in.
    let workingDirectory: String
    /// The conversation, from its validated session file.
    let sessionID: String
    /// The session file's status at plan time.
    let status: String
    /// The `PATH` the agent ran with, so `claude update` finds what its installation needs (npm).
    let searchPath: String?
    /// Its Claude configuration folder (`CLAUDE_CONFIG_DIR` or `~/.claude`).
    let configRoot: URL
    /// What to type to reopen it: never a `versions/<x>` path.
    let launcher: String
    /// The absolute path of that launcher, for `auth status` and `update`; `nil` if unresolved.
    let launcherPath: String?
    /// The running version, from the session file.
    let version: String?

    /// Whether it was in the middle of a turn.
    ///
    /// Only `busy`. `shell` is what Claude writes while a background shell runs and the agent
    /// itself is idle (measured on 2.1.321): telling it «estabas trabajando» would be false.
    var wasWorking: Bool { status == "busy" }
}
