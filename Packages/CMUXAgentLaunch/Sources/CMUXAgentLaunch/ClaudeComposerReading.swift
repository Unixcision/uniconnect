import Foundation

/// What Claude Code's composer holds, read from a styled pane capture.
///
/// Typing `/exit` and Enter over a half-written message would **send** that message, so a close
/// only types when the composer is provably empty. Empty is not "no text": Claude shows a dimmed
/// suggestion (`❯ Try "refactor <filepath>"`) in an empty composer, and only the styling tells it
/// apart from the same words typed by a person. So the reading needs `capture-pane -e`.
///
/// The composer is the prompt line (`❯ ` or the older `> `) right below a horizontal rule
/// (`────`) or a box top (`╭───`), plus its continuation lines down to the next rule; the lowest
/// one on screen is the live one. Menus that also draw `❯` (the slash-command list, the trust
/// question) are not under a rule and are not mistaken for it.
public enum ClaudeComposerReading: Sendable, Equatable {
    /// Nothing typed: only the cursor, or a dimmed suggestion.
    case empty
    /// The person's own text, which must survive the relaunch (written back without return).
    case draft(String)
    /// No composer recognised on screen. Nothing is typed into it.
    case unrecognised

    /// Reads a styled capture.
    ///
    /// - Parameter styledText: `capture-pane -e -p` output, escapes included.
    /// - Returns: The composer's state.
    public static func read(styledText: String) -> ClaudeComposerReading {
        let styled = styledText.components(separatedBy: "\n")
        let plain = styled.map(ClaudeStyledLine.init(styled:))
        guard let prompt = promptRow(in: plain) else { return .unrecognised }

        var parts: [String] = []
        let first = plain[prompt].afterPrompt
        if !first.isMutedText { parts.append(first.text) }
        var row = prompt + 1
        while row < plain.count, !plain[row].isRule {
            let line = plain[row].continuation
            if !line.isMutedText { parts.append(line.text) }
            row += 1
        }
        let text = parts
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .empty : .draft(text)
    }

    /// The row of the live prompt line: the lowest `❯`/`>` line right below a rule or box top.
    private static func promptRow(in lines: [ClaudeStyledLine]) -> Int? {
        var found: Int?
        for row in lines.indices.dropFirst() where lines[row - 1].isRule && lines[row].isPrompt {
            // A composer is closed by a rule below it; without one this is not the composer.
            guard lines[(row + 1)...].contains(where: \.isRule) else { continue }
            found = row
        }
        return found
    }
}
