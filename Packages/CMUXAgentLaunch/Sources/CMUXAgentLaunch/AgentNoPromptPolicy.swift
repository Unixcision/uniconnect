import Foundation

/// The single "resume without asking" policy shared by macOS, Linux and the VPS supervisor.
///
/// It reads the `noPrompt` entry each provider carries in `agent-resume-v1.json`:
///
/// - Claude: `--dangerously-skip-permissions` at the end, and `IS_SANDBOX=1` when running as root.
/// - Codex: `--yolo` right after the executable; the older `--dangerously-bypass-approvals-and-sandbox`
///   is removed first, and so are the flags `--yolo` replaces and the CLI refuses next to it
///   (`-a`/`--ask-for-approval` and `-s`/`--sandbox` with their value, and `--full-auto`).
/// - Antigravity (`agy`): `--dangerously-skip-permissions` right after the executable.
/// - Grok: no verified flag, so it resumes with the catalogue syntax and
///   ``AgentNoPromptResume/noPromptVerified`` set to `false`.
///
/// ```swift
/// let policy = try AgentNoPromptPolicy()
/// policy.resume(provider: "codex", sessionID: id, asRoot: false)?.argv
/// // ["codex", "--yolo", "resume", id]
/// ```
///
/// Tests build it from explicit catalogue bytes with ``init(data:)``.
public struct AgentNoPromptPolicy: Sendable, Equatable {
    private let catalog: AgentResumeCatalog

    /// Loads the policy from the catalogue bundled with this package.
    ///
    /// - Throws: An error when the catalogue is missing from the deployment or its schema is invalid.
    public init() throws {
        try self.init(locator: AgentResumeResourceLocator())
    }

    /// Loads the policy from the catalogue a locator finds.
    init(locator: AgentResumeResourceLocator) throws {
        catalog = try AgentResumeCatalog(locator: locator)
    }

    /// Builds the policy from explicit catalogue bytes, for isolated tests.
    ///
    /// - Parameter data: Versioned JSON with the same shape as `agent-resume-v1.json`.
    /// - Throws: A decoding or schema error when the catalogue or any `noPrompt` entry is invalid.
    public init(data: Data) throws {
        catalog = try AgentResumeCatalog(data: data)
    }

    /// Shares an already-decoded catalogue with the resume argv builder.
    init(catalog: AgentResumeCatalog) {
        self.catalog = catalog
    }

    /// Builds the no-prompt resume command for one conversation.
    ///
    /// - Parameters:
    ///   - provider: The provider id or alias (`claude`, `codex`, `agy`, `antigravity`, `grok`, …).
    ///   - sessionID: The conversation id; it must match `[A-Za-z0-9_-]{1,160}`.
    ///   - asRoot: Whether the agent runs as uid 0, which adds the provider's root environment.
    ///   - arguments: Window options preserved after the conversation id (for example `-C <cwd>`).
    /// - Returns: The command, or `nil` for an unknown provider or an invalid conversation id.
    public func resume(
        provider: String,
        sessionID: String,
        asRoot: Bool,
        arguments: [String] = []
    ) -> AgentNoPromptResume? {
        guard Self.isValidSessionID(sessionID),
              let canonical = catalog.canonicalKind(provider),
              let entry = catalog.providers[canonical],
              let argv = catalog.argv(
                  kind: canonical,
                  sessionId: sessionID,
                  executable: entry.executable,
                  arguments: arguments
              ) else { return nil }
        return applying(to: argv, provider: canonical, asRoot: asRoot)
    }

    /// The argv that starts a **new** conversation of `provider` without questions.
    ///
    /// The catalogue's executable with the same `noPrompt` flags a resume gets, so a new window and
    /// a resumed one never drift apart: `claude --dangerously-skip-permissions`, `codex --yolo`,
    /// `agy --dangerously-skip-permissions`, and plain `grok`.
    ///
    /// ```swift
    /// try AgentNoPromptPolicy().launch(provider: "codex")?.argv  // ["codex", "--yolo"]
    /// ```
    ///
    /// - Parameters:
    ///   - provider: The provider id or alias.
    ///   - asRoot: Whether the agent runs as uid 0, which adds the provider's root environment.
    /// - Returns: The command, or `nil` for a provider the catalogue does not know.
    public func launch(provider: String, asRoot: Bool = false) -> AgentNoPromptResume? {
        guard let canonical = catalog.canonicalKind(provider),
              let entry = catalog.providers[canonical] else { return nil }
        return applying(to: [entry.executable], provider: canonical, asRoot: asRoot)
    }

    /// Applies the provider's no-prompt mode to an argv that already resumes a conversation.
    ///
    /// Everything after the executable is walked left to right: a prefix, suffix or legacy flag is
    /// removed; a superseded flag is removed together with its value when it takes one (the next
    /// token, or `flag=value`, short flags included); everything else stays in order. Then the prefix
    /// is inserted right after `argv[0]` and the suffix appended, once each. Applying it twice gives
    /// the same result as applying it once. A provider without a `noPrompt` entry keeps its argv
    /// unchanged. The glued short form (`-anever`) is not recognised: the catalogue never produces it.
    ///
    /// ```swift
    /// policy.applying(to: ["codex", "resume", id, "-a", "never", "-m", "gpt-5"], provider: "codex", asRoot: false).argv
    /// // ["codex", "--yolo", "resume", id, "-m", "gpt-5"]
    /// ```
    ///
    /// - Parameters:
    ///   - argv: The argument vector, executable first.
    ///   - provider: The provider id or alias.
    ///   - asRoot: Whether the root environment is exported.
    /// - Returns: The adjusted command.
    public func applying(to argv: [String], provider: String, asRoot: Bool) -> AgentNoPromptResume {
        let canonical = catalog.canonicalKind(provider) ?? provider
        guard let policy = catalog.providers[canonical]?.noPrompt, let executable = argv.first else {
            return AgentNoPromptResume(argv: argv, environment: [:], noPromptVerified: false)
        }
        let known = policy.allFlags
        var takesValue: [String: Bool] = [:]
        for entry in policy.supersedes ?? [] {
            takesValue[entry.flag] = entry.takesValue
        }
        var rest: [String] = []
        var index = argv.index(after: argv.startIndex)
        while index < argv.endIndex {
            let token = argv[index]
            index = argv.index(after: index)
            if known.contains(token) { continue }
            if let consumesNext = takesValue[token] {
                if consumesNext, index < argv.endIndex {
                    index = argv.index(after: index)
                }
                continue
            }
            if let separator = token.firstIndex(of: "="),
               takesValue[String(token[..<separator])] == true {
                continue
            }
            rest.append(token)
        }
        let adjusted = [executable] + (policy.prefix ?? []) + rest + (policy.suffix ?? [])
        return AgentNoPromptResume(
            argv: adjusted,
            environment: asRoot ? (policy.rootEnvironment ?? [:]) : [:],
            noPromptVerified: true
        )
    }

    /// Whether the provider has a verified no-prompt mode in the catalogue.
    ///
    /// - Parameter provider: The provider id or alias.
    /// - Returns: `false` for Grok and for providers the catalogue does not know.
    public func isVerified(provider: String) -> Bool {
        guard let canonical = catalog.canonicalKind(provider) else { return false }
        return catalog.providers[canonical]?.noPrompt != nil
    }

    /// The name people read for a provider, from the catalogue's `displayName`.
    ///
    /// Mac, Linux and Android show the same text (`Claude Code`, `Codex`, `Antigravity`, `Grok`);
    /// no platform keeps its own table of names.
    ///
    /// - Parameter provider: A catalogue id or alias (`agy` and `antigravity` both work).
    /// - Returns: The catalogue's `displayName`, or `provider` itself when the catalogue has none.
    public func displayName(provider: String) -> String {
        guard let canonical = catalog.canonicalKind(provider),
              let name = catalog.providers[canonical]?.displayName else { return provider }
        return name
    }

    /// The provider id used on the wire (`antigravity` travels as `agy`).
    ///
    /// - Parameter provider: A catalogue id or alias.
    /// - Returns: The canonical wire id: `claude`, `codex`, `agy`, `grok` or the catalogue id.
    public func wireProvider(_ provider: String) -> String {
        let canonical = catalog.canonicalKind(provider) ?? provider
        return canonical == "antigravity" ? "agy" : canonical
    }

    /// Whether `sessionID` is a conversation id every platform accepts.
    ///
    /// - Parameter sessionID: The candidate id.
    /// - Returns: `true` when it matches `[A-Za-z0-9_-]{1,160}`.
    public static func isValidSessionID(_ sessionID: String) -> Bool {
        sessionID.range(of: #"^[A-Za-z0-9_-]{1,160}$"#, options: .regularExpression) != nil
    }
}
