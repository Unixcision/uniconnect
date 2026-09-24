import Foundation

/// Reads Claude Code's per-process session files under one configuration folder.
///
/// A file only counts while its process is alive **and** is Claude: a stale `<pid>.json` whose pid
/// was recycled by another program says nothing. The liveness check is injected so tests run on a
/// temporary folder with fake processes.
///
/// ```swift
/// let sessions = AgentClaudeSessionDirectory(
///     root: home.appendingPathComponent(".claude"),
///     isLiveClaude: { pid in table[pid]?.isClaude == true }
/// )
/// sessions.liveHolders(sessionID: id).isEmpty  // nobody has this conversation open
/// ```
public struct AgentClaudeSessionDirectory: Sendable {
    /// The Claude configuration folder (`~/.claude` or `CLAUDE_CONFIG_DIR`); files live in `sessions/`.
    public let root: URL
    private let isLiveClaude: @Sendable (Int) -> Bool

    /// Creates a reader for one configuration folder.
    ///
    /// - Parameters:
    ///   - root: The Claude configuration folder, not its `sessions` subfolder.
    ///   - isLiveClaude: Whether `pid` is alive and its command line is Claude's.
    public init(root: URL, isLiveClaude: @escaping @Sendable (Int) -> Bool) {
        self.root = root
        self.isLiveClaude = isLiveClaude
    }

    private var sessionsFolder: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session file of a live Claude process.
    ///
    /// - Parameter pid: The Claude process id.
    /// - Returns: The file, or `nil` when there is none or the pid is not a live Claude.
    public func file(pid: Int) -> AgentClaudeSessionFile? {
        guard pid > 0 else { return nil }
        let url = sessionsFolder.appendingPathComponent("\(pid).json", isDirectory: false)
        guard let file = AgentClaudeSessionFile.read(at: url), isLiveClaude(pid) else { return nil }
        return file
    }

    /// The live Claude processes that have `sessionID` open right now.
    ///
    /// - Parameter sessionID: The conversation id, compared case-insensitively.
    /// - Returns: The pids, sorted; empty when the conversation is free to resume.
    public func liveHolders(sessionID: String) -> [Int] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsFolder.path) else { return [] }
        let wanted = sessionID.lowercased()
        var holders: [Int] = []
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int(name.dropLast(5)), pid > 0,
                  let file = AgentClaudeSessionFile.read(at: sessionsFolder.appendingPathComponent(name)),
                  file.sessionId.lowercased() == wanted,
                  isLiveClaude(pid) else { continue }
            holders.append(pid)
        }
        return holders.sorted()
    }
}
