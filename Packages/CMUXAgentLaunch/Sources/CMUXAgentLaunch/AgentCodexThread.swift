import Foundation

/// One row of Codex's `threads` table (`$CODEX_HOME/state_<n>.sqlite`), as the discovery needs it.
///
/// Codex 0.166 and later keep a conversation in SQLite and talk to an app-server: the TUI no longer
/// holds its rollout open, so a `codex` started by hand without `resume <uuid>` has no other trace of
/// which conversation it is on (`contracts/agent-tree-v1`, source `threads`, 10-11-2026).
public struct AgentCodexThread: Sendable, Equatable, Codable {
    /// The conversation id.
    public let id: String
    /// The folder the conversation runs in, as Codex wrote it.
    public let workingDirectory: String
    /// When the thread was created, in milliseconds since 1970.
    public let createdAtMilliseconds: Int64
    /// When the thread last changed, in milliseconds since 1970.
    public let updatedAtMilliseconds: Int64
    /// Who created it (`codex-tui` for the terminal UI, `Codex Desktop`, `codex_exec`…).
    public let originator: String?
    /// Whether it was archived.
    public let archived: Bool
    /// `user` for a conversation, `subagent` for a sub-agent's own thread.
    public let threadSource: String?

    /// Creates a row.
    ///
    /// - Parameters:
    ///   - id: The conversation id.
    ///   - workingDirectory: Its folder.
    ///   - createdAtMilliseconds: Creation time in ms.
    ///   - updatedAtMilliseconds: Last change in ms.
    ///   - originator: Who created it.
    ///   - archived: Whether it was archived.
    ///   - threadSource: `user` or `subagent`.
    public init(
        id: String,
        workingDirectory: String,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        originator: String?,
        archived: Bool,
        threadSource: String? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.originator = originator
        self.archived = archived
        self.threadSource = threadSource
    }

    /// Whether this is a conversation the Codex terminal UI started: `codex-tui`, not archived, and
    /// not a sub-agent's thread (those share the folder and the originator).
    public var isTerminalConversation: Bool {
        originator == "codex-tui" && !archived && threadSource != "subagent"
    }
}
