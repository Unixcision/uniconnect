import Foundation

/// How Codex is read, identified and relaunched, calcado del trabajador de Linux (`exit_codex`).
///
/// - **Identity** comes from the rollout the live Codex holds open (the `agent-tree.v1` rule),
///   proven **before** closing: Codex does not print a conversation worth trusting on its way out.
/// - **Closing** only with an empty composer (`›` alone, or the dimmed placeholder
///   `› Ask Codex to do anything` with the cursor at column 2). `/exit` is typed literally, return is
///   pressed only once `› /exit` is on the cursor line, and the process is waited for, never killed.
///   A permission or trust question on screen is ``RelaunchCause/permissions``: a person answers it.
/// - **Reopening** is `codex --yolo resume <id> <kept options>`, with the shared `noPrompt` policy
///   and its `supersedes` applied (no `-a`, `--ask-for-approval`, `-s`, `--sandbox`, `--full-auto`).
///
/// ```swift
/// CodexRelaunchDialect().invocation(conversation: id, previousArgv: ["node", "/usr/local/bin/codex", "-m", "gpt-5"])
/// // ["codex", "--yolo", "resume", id, "-m", "gpt-5"]
/// ```
public struct CodexRelaunchDialect: RelaunchAgentDialect {
    public let provider = "codex"

    /// The shared no-prompt policy, or `nil` when the bundled catalogue could not be read.
    private let policy: AgentNoPromptPolicy?

    /// Creates the dialect with the no-prompt policy bundled with this package.
    public init() {
        policy = try? AgentNoPromptPolicy()
    }

    /// Creates the dialect with an explicit no-prompt policy, for isolated tests.
    ///
    /// - Parameter policy: The policy to apply; `nil` makes every invocation a refusal, because the
    ///   flags `--yolo` replaces could not be removed.
    public init(policy: AgentNoPromptPolicy?) {
        self.policy = policy
    }

    /// Characters that stop being themselves once a shell reads them, or that `ps` may have split.
    private static let shellSyntax = CharacterSet(charactersIn: ";|&$`()<>\n\r\t\\\"'*?[]{}~#!")

    /// Options that take exactly one value, the next token.
    private static let optionsTakingValue: Set<String> = [
        "-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval",
        "-C", "--cd", "--add-dir", "--local-provider", "--enable", "--disable",
    ]

    /// Options that stand alone.
    private static let flags: Set<String> = [
        "--yolo", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--oss", "--search",
        "--no-alt-screen",
    ]

    /// Texts that mean Codex is asking something a person has to answer.
    private static let questions = [
        "do you trust", "trust this", "allow once", "allow execution", "would you like to run",
        "do you want to proceed", "[y/n]", "sign in", "log in",
    ]

    public var closing: RelaunchClosing { .confirmedCommand("/exit") }

    public func read(screen: String) -> RelaunchScreenReading {
        switch RelaunchScreenReading.read(screen: screen) {
        case .shellPrompt:
            return .shellPrompt
        case .folderTrustQuestion:
            return .folderTrustQuestion
        default:
            return .unrecognised
        }
    }

    public func conversation(from evidence: RelaunchIdentityEvidence) -> String? {
        evidence.provenConversation
    }

    /// Why the pane may not be closed now; `nil` when Codex sits at an empty composer.
    ///
    /// A draft, a list or anything unrecognised under the cursor is ``RelaunchCause/unknownDialog``;
    /// a question on screen is ``RelaunchCause/permissions``.
    public func refusalToClose(screen: RelaunchPaneScreen) -> RelaunchCause? {
        guard let line = screen.cursorLine else { return .unknownDialog }
        var empty = line.range(of: #"^\s*[›❯>]\s*$"#, options: .regularExpression) != nil
        if !empty, line == "› Ask Codex to do anything", screen.cursorColumn == 2 {
            // The dimmed placeholder with the cursor before it, not a draft with the same words.
            let styled = screen.styledLines
            empty = screen.cursorRow < styled.count && styled[screen.cursorRow].range(
                of: #"^(?:\x1b\[[0-9;]*m)*›(?:\x1b\[[0-9;]*m)* \x1b\[2mAsk Codex to do anything(?:\x1b\[[0-9;]*m)*$"#,
                options: .regularExpression
            ) != nil
        }
        guard empty else { return .unknownDialog }
        let visible = screen.lines.joined(separator: "\n").lowercased()
        if Self.questions.contains(where: { visible.contains($0) }) { return .permissions }
        return nil
    }

    /// Whether the exit command sits typed on the cursor line, ready for return.
    public func showsCloseCommand(screen: RelaunchPaneScreen) -> Bool {
        screen.cursorLine?.trimmingCharacters(in: .whitespacesAndNewlines) == "› /exit"
    }

    public func resumes(conversation: String, argv: [String]) -> Bool {
        let options = argv.prefix { $0 != "--" }
        guard let index = options.firstIndex(of: "resume"), options.indices.contains(index + 1) else { return false }
        return options[index + 1].lowercased() == conversation.lowercased()
    }

    public func invocation(conversation: String, previousArgv: [String]) -> [String]? {
        guard AgentNoPromptPolicy.isValidSessionID(conversation), let policy else { return nil }
        var kept: [String] = []
        if !previousArgv.isEmpty {
            // `node /usr/local/bin/codex …` or `codex …`: everything after the Codex executable.
            guard let start = previousArgv.firstIndex(where: {
                ($0 as NSString).lastPathComponent.hasPrefix("codex")
            }) else { return nil }
            var index = previousArgv.index(after: start)
            var sawResume = false
            while index < previousArgv.endIndex {
                let token = previousArgv[index]
                index = previousArgv.index(after: index)
                // Something `ps` may have flattened, or that a shell would read as syntax: this
                // window cannot be given back as it was, so it is left alone.
                guard !token.isEmpty, token.rangeOfCharacter(from: Self.shellSyntax) == nil, token != "--" else {
                    return nil
                }
                if token == "resume", !sawResume {
                    sawResume = true
                    if index < previousArgv.endIndex, !previousArgv[index].hasPrefix("-") {
                        index = previousArgv.index(after: index)
                    }
                    continue
                }
                if token == "--last" { continue }
                if token.hasPrefix("--"), token.contains("=") {
                    kept.append(token)
                    continue
                }
                if Self.optionsTakingValue.contains(token) {
                    guard index < previousArgv.endIndex else { return nil }
                    let value = previousArgv[index]
                    guard !value.hasPrefix("-"), value.rangeOfCharacter(from: Self.shellSyntax) == nil else {
                        return nil
                    }
                    kept += [token, value]
                    index = previousArgv.index(after: index)
                    continue
                }
                if Self.flags.contains(token) {
                    kept.append(token)
                    continue
                }
                // An unknown option (its value is unknowable) or a stray word (a prompt): refuse.
                return nil
            }
        }
        return policy.applying(to: ["codex", "resume", conversation] + kept, provider: provider, asRoot: false).argv
    }
}
