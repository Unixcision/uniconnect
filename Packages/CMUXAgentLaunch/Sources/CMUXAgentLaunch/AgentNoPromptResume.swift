import Foundation

/// A resume command that brings a conversation back without stopping on any question.
///
/// It is always **derived** — from the provider, the conversation id, the folder and whether the
/// agent runs as root — and never persisted: a stored argv can carry secrets and goes stale.
/// ``AgentNoPromptPolicy`` builds it from the shared `noPrompt` entries of the resume catalogue,
/// the same ones Linux and the VPS supervisor read.
///
/// ```swift
/// let policy = try AgentNoPromptPolicy()
/// let resume = policy.resume(provider: "claude", sessionID: id, asRoot: true)
/// resume?.shellLine(workingDirectory: "/root/xunis")
/// // cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume <id> --dangerously-skip-permissions
/// ```
public struct AgentNoPromptResume: Sendable, Equatable {
    /// The argument vector, executable first, with the no-prompt flags applied exactly once.
    public let argv: [String]
    /// Variables exported before the command, such as `IS_SANDBOX=1` for Claude running as root.
    ///
    /// Keys match `^[A-Z_][A-Z0-9_]*$` and values `^[A-Za-z0-9._-]{1,64}$`, so they never need quoting.
    public let environment: [String: String]
    /// Whether the provider has a verified no-prompt mode; `false` means it resumes with plain syntax.
    public let noPromptVerified: Bool

    /// Creates a resume command from already-validated parts.
    ///
    /// - Parameters:
    ///   - argv: The argument vector, executable first.
    ///   - environment: Variables to export before running `argv`.
    ///   - noPromptVerified: Whether the provider's no-prompt mode is verified.
    public init(argv: [String], environment: [String: String], noPromptVerified: Bool) {
        self.argv = argv
        self.environment = environment
        self.noPromptVerified = noPromptVerified
    }

    /// The POSIX shell line that changes to `workingDirectory` and runs the command.
    ///
    /// The folder is always single-quoted (`'` becomes `'\''`); an argv token is only quoted when it
    /// contains something outside `[A-Za-z0-9@%_+=:,./-]`; `K=V` pairs go unquoted, sorted by key,
    /// right before the executable.
    ///
    /// - Parameter workingDirectory: The folder to resume in, or `nil` to omit the `cd`.
    /// - Returns: For example `cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume <id> --dangerously-skip-permissions`.
    public func shellLine(workingDirectory: String?) -> String {
        let assignments = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        let command = (assignments + argv.map(Self.quotedIfNeeded)).joined(separator: " ")
        guard let workingDirectory, !workingDirectory.isEmpty else { return command }
        return "cd -- \(Self.singleQuoted(workingDirectory)) && \(command)"
    }

    /// Characters that never need quoting in a POSIX shell word.
    private static let plainCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%_+=:,./-")

    private static func quotedIfNeeded(_ token: String) -> String {
        guard !token.isEmpty, token.allSatisfy({ plainCharacters.contains($0) }) else {
            return singleQuoted(token)
        }
        return token
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
