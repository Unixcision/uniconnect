import Foundation

/// Builds the argument vector for an agent's resume/continue command.
///
/// This is the single source of truth shared by the app-side resume builder
/// (`AgentResumeCommandBuilder` in the app target) and the standalone `cmux-cli` surface-restore
/// publisher (`agentSurfaceResumeCommand`), so both emit identical resume commands. It is pure value
/// logic over primitives (no `AppKit`, `Process`, or socket), so it is testable in isolation.
///
/// Command syntax comes from the package resource also consumed by Linux. This value keeps
/// captured-argument sanitization, cmux wrappers and the existing macOS trust policy in Swift.
///
/// Resolution order mirrors the historical app builder: a cmux wrapper launcher
/// (``launcherResolution(launcher:sessionId:executablePath:arguments:)``) is checked first, then the
/// per-kind verb (``builtInKind(kind:sessionId:executablePath:arguments:)``). Callers that also
/// support custom Vault agents slot that resolution between the two.
public struct AgentResumeArgv: Sendable, Equatable {
    private let catalog: AgentResumeCatalog?

    /// Creates a resume-argv builder using the bundled cross-platform command catalogue.
    public init() {
        catalog = try? AgentResumeCatalog()
    }

    /// Creates a resume-argv builder from an explicit command catalogue for isolated tests.
    ///
    /// - Parameter catalogData: Versioned JSON command syntax, with no approval policy.
    /// - Throws: A decoding or schema error when the catalogue is invalid.
    public init(catalogData: Data) throws {
        catalog = try AgentResumeCatalog(data: catalogData)
    }

    /// The result of resolving a cmux wrapper launcher (the `claude-teams` / `codex-teams` / `omo`
    /// style launchers cmux injects), checked before the per-kind verb.
    public enum LauncherResolution: Sendable, Equatable {
        /// The launcher is a cmux wrapper; the associated value is its resume argv, or `nil` when the
        /// wrapper has no resumable form (e.g. one-shot `omx`/`omc`).
        case resolved([String]?)
        /// The launcher is a plain agent executable; fall through to ``builtInKind(kind:sessionId:executablePath:arguments:)``.
        case passthrough
    }

    /// Resolves a resume argv from a cmux wrapper launcher, or ``LauncherResolution/passthrough`` when
    /// the launcher is a plain agent executable.
    ///
    /// - Parameters:
    ///   - launcher: the captured launcher token (e.g. `"claudeTeams"`, `"omo"`), or `nil`.
    ///   - sessionId: the session/thread id to resume.
    ///   - executablePath: the captured executable path, if any.
    ///   - arguments: the captured launch arguments (argv, including the executable as element 0).
    public func launcherResolution(
        launcher: String?,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> LauncherResolution {
        switch launcher {
        case "claudeTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "claude-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: tail) else {
                return .resolved(nil)
            }
            guard let argv = catalog?.argv(kind: "claude", sessionId: sessionId, executable: parts.executable, arguments: preserved) else {
                return .resolved(nil)
            }
            return .resolved(
                appendingRequiredOption(
                    "--dangerously-skip-permissions",
                    to: [parts.executable, "claude-teams"] + argv.dropFirst()
                )
            )
        case "codexTeams":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "codex-teams" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedCodexForkArguments(args: tail) else {
                return .resolved(nil)
            }
            guard let argv = catalog?.argv(kind: "codex", sessionId: sessionId, executable: parts.executable, arguments: preserved) else {
                return .resolved(nil)
            }
            return .resolved(
                appendingRequiredOption(
                    "--yolo",
                    to: [parts.executable, "codex-teams"] + argv.dropFirst()
                )
            )
        case "omo":
            let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "cmux")
            var tail = parts.tail
            if tail.first == "omo" { tail.removeFirst() }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: tail) else {
                return .resolved(nil)
            }
            guard let argv = catalog?.argv(kind: "opencode", sessionId: sessionId, executable: parts.executable, arguments: preserved) else {
                return .resolved(nil)
            }
            return .resolved([parts.executable, "omo"] + argv.dropFirst())
        case "omx", "omc":
            return .resolved(nil)
        default:
            return .passthrough
        }
    }

    /// Builds the resume argv for a built-in agent kind, or `nil` if the kind is unknown or its launch
    /// arguments cannot be preserved.
    ///
    /// - Parameters:
    ///   - kind: the agent's raw kind identifier (e.g. `"claude"`, `"codex"`, `"hermes-agent"`).
    ///   - sessionId: the session/thread id to resume.
    ///   - executablePath: the captured executable path, if any.
    ///   - arguments: the captured launch arguments (argv, including the executable as element 0).
    public func builtInKind(
        kind: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        guard let catalog, let kind = catalog.canonicalKind(kind), let provider = catalog.providers[kind] else { return nil }
        if kind == "claude" {
            return claudeResumeArgv(sessionId: sessionId, executablePath: executablePath, arguments: arguments)
        }
        let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: provider.executable)
        let preserved = kind == "codex"
            ? AgentLaunchSanitizer.preservedCodexForkArguments(args: parts.tail)
            : AgentLaunchSanitizer.preservedArguments(kind: kind, args: parts.tail)
        guard let preserved,
              let argv = catalog.argv(kind: kind, sessionId: sessionId, executable: parts.executable, arguments: preserved) else { return nil }
        switch kind {
        case "codex": return appendingRequiredOption("--yolo", to: argv)
        case "antigravity": return appendingRequiredOption("--dangerously-skip-permissions", to: argv)
        default: return argv
        }
    }

    /// Builds the claude resume argv, routing it through cmux's `claude` wrapper
    /// so cmux hooks fire on the resumed session.
    ///
    /// cmux injects Claude Code's hook `--settings` from the `Resources/bin/claude`
    /// wrapper, which is first on `PATH` inside cmux terminals. The wrapper
    /// re-injects those hooks whenever it sees `--resume`, exactly as it does on a
    /// fresh launch (and it also re-applies the rest of the fresh-launch setup:
    /// `CLAUDE_CONFIG_DIR` normalization, auth-selection env handling, NODE_OPTIONS,
    /// nested-session unset). The captured launch executable, however, is the
    /// *real* claude binary (`CMUX_AGENT_LAUNCH_EXECUTABLE`), so resuming with it
    /// directly bypassed the wrapper and dropped every hook
    /// (https://github.com/manaflow-ai/cmux/issues/5427).
    ///
    /// Forcing the executable to the bare `claude` wrapper is the same thing the
    /// session-index resume builder (`SessionEntry.resumeCommand`) already does,
    /// so both resume paths now share one injection point. The captured executable
    /// is intentionally ignored for claude; the wrapper resolves the real binary
    /// (honouring `CMUX_CUSTOM_CLAUDE_PATH`).
    private func claudeResumeArgv(
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        let parts = commandParts(executablePath: executablePath, arguments: arguments, fallbackExecutable: "claude")
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: parts.tail) else {
            return nil
        }
        guard let argv = catalog?.argv(kind: "claude", sessionId: sessionId, executable: "claude", arguments: preserved) else {
            return nil
        }
        // UniConnect: restored sessions must never stop on a permission prompt.
        return appendingRequiredOption(
            "--dangerously-skip-permissions",
            to: argv
        )
    }

    /// Appends a UniConnect trust-mode option exactly once to a reconstructed launch.
    private func appendingRequiredOption(_ option: String, to argv: [String]) -> [String] {
        guard !argv.contains(option) else { return argv }
        return argv + [option]
    }

    private func commandParts(
        executablePath: String?,
        arguments: [String],
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let executable = normalized(executablePath) ?? normalized(arguments.first) ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
