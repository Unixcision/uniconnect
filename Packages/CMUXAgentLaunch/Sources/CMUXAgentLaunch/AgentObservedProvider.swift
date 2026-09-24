import Foundation

/// An agent the process discovery recognises, by its canonical wire id.
///
/// The raw values are the ids of the `agent-tree.v1` contract, shared with Linux, Android and the
/// VPS supervisor. The resume catalogue calls Antigravity `antigravity`; ``catalogKind`` maps it.
public enum AgentObservedProvider: String, Sendable, Codable, CaseIterable {
    /// Claude Code.
    case claude
    /// OpenAI Codex CLI.
    case codex
    /// Google Antigravity (`agy`).
    case agy
    /// Grok CLI.
    case grok

    /// The provider id used by `agent-resume-v1.json`.
    public var catalogKind: String {
        self == .agy ? "antigravity" : rawValue
    }

    /// Classifies one process, or returns `nil` when it is not an agent.
    ///
    /// `sudo`, `env`, shells, `login` and an unmarked `node` are never an agent: their children are
    /// already part of the subtree being inspected. A Claude session file alone does not make a
    /// process Claude, because its pid may have been recycled: it also needs an argument that
    /// mentions `claude`.
    ///
    /// - Parameters:
    ///   - process: The process row.
    ///   - hasClaudeSession: Whether a Claude session file exists for this pid.
    /// - Returns: The provider the process belongs to.
    public static func classify(_ process: AgentProcessSample, hasClaudeSession: Bool) -> AgentObservedProvider? {
        if hasClaudeSession, process.arguments.contains(where: { $0.contains("claude") }) {
            return .claude
        }
        let name = process.executableName
        let executable = process.arguments.first ?? ""
        let rest = process.arguments.dropFirst()
        let isScriptHost = ["node", "bun"].contains(name) || name.hasPrefix("node")
        if name == "claude" || executable.contains("/.local/share/claude/versions/") {
            return .claude
        }
        if isScriptHost, rest.contains(where: { $0.contains("@anthropic-ai/claude-code") }) {
            return .claude
        }
        if name.hasPrefix("codex") {
            return .codex
        }
        if isScriptHost, rest.contains(where: { argument in
            let base = (argument as NSString).lastPathComponent
            return argument.contains("@openai/codex") || base == "codex" || base == "codex.js"
        }) {
            return .codex
        }
        if name == "agy" || name == "antigravity" {
            return .agy
        }
        if name == "grok" || name.hasPrefix("grok-") {
            return .grok
        }
        return nil
    }
}
