import Foundation

/// The conversation an agent in a tmux pane is on, as read from the live process right now.
///
/// It is an observation, not a record: the caller decides whether to persist it. The working
/// folder is reported as found; callers resolve it with `realpath` before storing it.
public struct AgentObservedConversation: Sendable, Equatable {
    /// Where the conversation id was read from, from most to least reliable.
    public enum Source: String, Sendable, Codable {
        /// Claude's `sessions/<pid>.json` of the live process.
        case sessionFile = "ficha"
        /// The `rollout-*-<uuid>.jsonl` a live Codex process holds open.
        case rollout
        /// The command line; it can be stale after `/clear` or an in-app `/resume`.
        case argv
    }

    /// The agent.
    public let provider: AgentObservedProvider
    /// The conversation id; lowercase when it is a UUID.
    public let sessionID: String
    /// The folder the agent works in, when known.
    public let workingDirectory: String?
    /// Whether the agent's root process runs as uid 0.
    public let asRoot: Bool
    /// Where ``sessionID`` came from.
    public let source: Source
    /// Claude's reported status (`idle`, `busy`, …), when the session file has one.
    public let status: String?
    /// The agent version, when the session file has one.
    public let version: String?
    /// The pid of the agent's root process in the pane.
    public let processID: Int

    /// Creates an observation.
    ///
    /// - Parameters:
    ///   - provider: The agent.
    ///   - sessionID: The conversation id.
    ///   - workingDirectory: The working folder, when known.
    ///   - asRoot: Whether the root process runs as uid 0.
    ///   - source: Where the id was read from.
    ///   - status: Claude's reported status.
    ///   - version: The agent version.
    ///   - processID: The pid of the agent's root process.
    public init(
        provider: AgentObservedProvider,
        sessionID: String,
        workingDirectory: String?,
        asRoot: Bool,
        source: Source,
        status: String? = nil,
        version: String? = nil,
        processID: Int
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.asRoot = asRoot
        self.source = source
        self.status = status
        self.version = version
        self.processID = processID
    }
}
