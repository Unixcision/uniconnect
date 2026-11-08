import Foundation

/// How a window's agent was asked to start, saved with the window from the moment it is created.
///
/// The agent's conversation reaches the saved state when it is known; this records what was asked
/// before that: which target, whether with `IS_SANDBOX=1`, and the conversation id chosen at
/// creation when the agent takes one (`claude --session-id`). The user the window runs as is a
/// property of the window, not of its agent (``UniConnectLocalWindowRecord/runAs``).
///
/// ```json
/// {"agent": "claude", "isSandbox": true, "sessionID": "6f1d2c3b-…"}
/// ```
struct UniConnectWindowLaunch: Codable, Equatable, Sendable {
    /// The launch target's id (`terminal`, `claude`, `codex`, `custom:<id>`, …).
    let agent: String
    /// Whether the agent starts with `IS_SANDBOX=1`.
    let isSandbox: Bool
    /// The conversation id the agent was started with, when it accepts one.
    let sessionID: String?

    init(agent: String, isSandbox: Bool, sessionID: String? = nil) {
        self.agent = agent
        self.isSandbox = isSandbox
        self.sessionID = sessionID
    }

    /// The agent's extra environment as the tree records it.
    var environment: [String: String] {
        isSandbox ? ["IS_SANDBOX": "1"] : [:]
    }

    /// Claude as root only starts without prompts with `IS_SANDBOX=1`: it is forced there, and the
    /// requested value counts for every other case.
    static func effectiveSandbox(requested: Bool, agent: String, runAs: UniConnectRunAs?) -> Bool {
        requested || (agent == UniConnectLocalWindowLaunchTarget.claude.id && runAs?.mode == .root)
    }
}
