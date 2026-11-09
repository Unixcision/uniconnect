import Foundation

/// A monitor or background shell a Claude started with its Bash tool, recognised from its argv.
///
/// Claude runs each Bash command through a wrapper shell that is a **direct child** of the Claude
/// process: `bash -c -l '<prologue> && eval '\''<command>'\'' < /dev/null && pwd -P >| …'` on
/// Linux, `/bin/zsh -c 'source …/shell-snapshots/… && … eval '\''<command>'\'' …'` on the Mac. The
/// prologue always mentions `unsetenv` or a `shell-snapshots` file; that is what tells a wrapper
/// apart from an MCP server or anything else Claude spawned. Closing the agent stops these, so the
/// command is saved first, exactly as written, and the agent gets it back after reopening
/// (`contracts/relaunch-v1/LEEME.md`, «Monitores y shells de fondo»).
///
/// ```swift
/// let shell = ClaudeBackgroundShell(argv: [
///     "/bin/bash", "-c", "-l",
///     "shopt -u extglob 2>/dev/null || true && { \\builtin unalias -- 'unsetenv'; } && eval 'bash /tmp/claude-0/x/scratchpad/monitor_poll.sh' < /dev/null",
/// ])
/// shell?.command          // "bash /tmp/claude-0/x/scratchpad/monitor_poll.sh"
/// shell?.referencedFiles  // ["/tmp/claude-0/x/scratchpad/monitor_poll.sh"]
/// ```
public struct ClaudeBackgroundShell: Sendable, Equatable {
    /// The command the agent asked to run, with the wrapper's quoting removed.
    public let command: String
    /// Paths under `/tmp/claude-<uid>/` or `/private/tmp/claude-<uid>/` the command mentions, in
    /// order of appearance and without repeats. The scratchpad may not survive a restart, so these
    /// are worth copying next to the saved command.
    public let referencedFiles: [String]

    private static let shells: Set<String> = ["bash", "zsh", "sh", "dash", "ksh"]

    /// Recognises a Claude Bash wrapper from its real argv.
    ///
    /// - Parameter argv: The process's arguments, as the kernel holds them (not `ps` text).
    /// - Returns: `nil` for anything that is not a Claude Bash wrapper with an `eval`.
    public init?(argv: [String]) {
        guard let executable = argv.first,
              Self.shells.contains((executable as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
              argv.count >= 3,
              let commandFlag = argv.firstIndex(of: "-c"), commandFlag > 0,
              let script = argv.last, argv.index(before: argv.endIndex) > commandFlag,
              argv[argv.index(after: commandFlag)..<argv.index(before: argv.endIndex)].allSatisfy({ $0.hasPrefix("-") }),
              let words = RelaunchShellWords(script) else { return nil }

        let tokens = words.tokens
        guard let evalIndex = tokens.firstIndex(of: .word("eval")) else { return nil }
        let prologue = tokens[..<evalIndex]
        let marked = prologue.contains { token in
            guard case let .word(text) = token else { return false }
            return text == "unsetenv" || text.contains("shell-snapshots")
        }
        guard marked else { return nil }

        var parts: [String] = []
        for token in tokens[tokens.index(after: evalIndex)...] {
            guard case let .word(text) = token else { break }
            parts.append(text)
        }
        let command = parts.joined(separator: " ")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.command = command
        self.referencedFiles = Self.temporaryFiles(in: command)
    }

    private static func temporaryFiles(in command: String) -> [String] {
        let pattern = #"(?:/private)?/tmp/claude-[0-9]+/[^\s'"\;|&<>()`$]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen: Set<String> = []
        var found: [String] = []
        let range = NSRange(command.startIndex..., in: command)
        for match in expression.matches(in: command, range: range) {
            guard let span = Range(match.range, in: command) else { continue }
            let path = String(command[span])
            if seen.insert(path).inserted { found.append(path) }
        }
        return found
    }
}
