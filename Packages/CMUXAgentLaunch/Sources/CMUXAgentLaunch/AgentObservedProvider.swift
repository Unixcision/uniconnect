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
    /// The strict criterion of `contracts/agent-tree-v1` (rule 2), shared with `agent_probe.py`,
    /// `agent_guard.py` and the VPS supervisor. A "node" is a basename of `argv[0]` matching
    /// `^(node|nodejs|bun)(\d+(\.\d+)*)?$`.
    ///
    /// - claude: basename `claude`; or `argv[0]` under `/claude/versions/`; or node with an argument
    ///   that contains `@anthropic-ai/claude-code` or whose basename is exactly `claude` (Claude from
    ///   npm launched through its shebang).
    /// - codex: basename starting with `codex` (the native `codex-x86_64-unknown-linux-musl` too); or
    ///   node with an argument that contains `@openai/codex` or whose basename is `codex`/`codex.js`.
    /// - agy: basename `agy` or `antigravity`. grok: basename `grok` or starting with `grok-`.
    ///
    /// `sudo`, `env`, shells, `login`, `tmux`, `python` and an unmarked node are never an agent: their
    /// children are already part of the subtree. A Claude session file **never** classifies a process
    /// (its pid may have been recycled by `vim ~/.claude/CLAUDE.md`); it only gives identity to a
    /// process that already is Claude.
    ///
    /// - Parameter process: The process row.
    /// - Returns: The provider the process belongs to.
    public static func classify(_ process: AgentProcessSample) -> AgentObservedProvider? {
        let name = process.executableName
        let executable = process.arguments.first ?? ""
        let rest = process.arguments.dropFirst()
        let isScriptHost = name.range(of: #"^(node|nodejs|bun)([0-9]+(\.[0-9]+)*)?$"#, options: .regularExpression) != nil
        if name == "claude" || executable.contains("/claude/versions/") {
            return .claude
        }
        if isScriptHost, rest.contains(where: { argument in
            argument.contains("@anthropic-ai/claude-code") || (argument as NSString).lastPathComponent == "claude"
        }) {
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
