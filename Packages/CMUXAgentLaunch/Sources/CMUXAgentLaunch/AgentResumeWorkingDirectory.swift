import Foundation

/// Resolves the working directory a restored agent session should run in.
///
/// This is the single source of truth shared by the app-side resolver
/// (``RestorableAgentSessionIndex`` in the app target) and the CLI surface-resume-binding publisher
/// (`publishAgentSurfaceResumeBinding` in the standalone `cmux-cli` target), so both apply one
/// policy: directory-namespaced agents pin the launch cwd, id-keyed agents keep the runtime cwd.
///
/// The type is a stateless value; construct one at the call site (`AgentResumeWorkingDirectory()`)
/// rather than reaching through a static namespace, per the package design discipline.
///
/// ```swift
/// // A Claude session launched in /repo that drifted into /repo/worktrees/x:
/// AgentResumeWorkingDirectory().resolve(
///     kind: "claude",
///     runtimeCwd: "/repo/worktrees/x",
///     launchWorkingDirectory: "/repo"
/// ) // == "/repo"  (so `claude --resume` finds the transcript filed under /repo)
/// ```
public struct AgentResumeWorkingDirectory: Sendable, Equatable {
    /// Creates a working-directory resolver. The type holds no state.
    public init() {}

    /// Classifies an agent by its raw kind id (e.g. `"claude"`, `"codex"`, `"hermes-agent"`).
    ///
    /// - Parameter kind: the agent's raw kind identifier (``RestorableAgentKind/rawValue`` in the app).
    /// - Returns: ``AgentCwdNamespacing/cwdInFile`` for id-keyed agents that record the cwd in the
    ///   session file; ``AgentCwdNamespacing/byDirectory`` for everything else (including unknown
    ///   kinds, which prefer the launch cwd).
    public func cwdNamespacing(forKind kind: String) -> AgentCwdNamespacing {
        switch kind {
        case "codex", "opencode", "amp", "antigravity", "rovodev", "hermes-agent":
            return .cwdInFile
        default:
            return .byDirectory
        }
    }

    /// The directory a resumed agent session should `cd` into.
    ///
    /// Directory-namespaced agents prefer the launch working directory: it is captured once at launch,
    /// matches the session store's namespace, and does not drift when the agent `cd`s into a
    /// subdirectory (e.g. a worktree) mid-session. Id-keyed agents keep the runtime cwd so they reopen
    /// where the agent was working. Inputs are trimmed and empty values are treated as absent.
    ///
    /// - Parameters:
    ///   - kind: the agent's raw kind identifier.
    ///   - runtimeCwd: the agent's last-reported runtime cwd (may have drifted).
    ///   - launchWorkingDirectory: the directory the agent was launched in.
    /// - Returns: the directory to `cd` into, or `nil` when neither input is usable.
    public func resolve(
        kind: String,
        runtimeCwd: String?,
        launchWorkingDirectory: String?
    ) -> String? {
        let runtime = normalized(runtimeCwd)
        let launch = normalized(launchWorkingDirectory)
        switch cwdNamespacing(forKind: kind) {
        case .cwdInFile:
            return runtime ?? launch
        case .byDirectory:
            return launch ?? runtime
        }
    }

    /// The physical path of an existing folder, with every symlink resolved, like POSIX `realpath`.
    ///
    /// Agents record the physical folder they run in (`getcwd`), so `~/Desktop/NOTBETTING` that
    /// links to `~/Developer/NOTBETTING` must be stored as the latter. Unlike
    /// `URL.resolvingSymlinksInPath`, `/private/tmp` stays `/private/tmp`.
    ///
    /// - Parameter path: An absolute path.
    /// - Returns: The resolved path, or `path` unchanged when it does not exist or cannot be read.
    public func realPath(_ path: String) -> String {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The folder name Claude Code files a working directory's transcripts under in `projects/`.
    ///
    /// Claude replaces every character that is not an ASCII letter or digit with `-` in the physical
    /// path, the same rule `linux/scripts/recovery.py` (`project_folder`) applies:
    /// `/Users/x/my_repo/.claude` becomes `-Users-x-my-repo--claude`.
    ///
    /// - Parameter workingDirectory: The folder Claude runs in.
    /// - Returns: The project folder name.
    public func claudeProjectFolderName(_ workingDirectory: String) -> String {
        var name = String.UnicodeScalarView()
        for scalar in realPath(workingDirectory).unicodeScalars {
            let isASCIIAlphanumeric = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            name.append(isASCIIAlphanumeric ? scalar : Unicode.Scalar(UInt8(ascii: "-")))
        }
        return String(name)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
