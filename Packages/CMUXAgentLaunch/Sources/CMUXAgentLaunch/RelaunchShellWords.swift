import Foundation

/// Splits shell text into words and operators, and quotes words back, the way a POSIX shell does.
///
/// Two jobs, both where getting quoting wrong closes or runs the wrong thing:
///
/// - **Reading** the script of a Claude Bash wrapper (`… && eval 'tail -F x | grep y' < /dev/null`)
///   to recover the exact command a monitor runs. Single quotes, double quotes with their four
///   escapes, backslashes and `$'…'` are honoured; operators (`&&`, `||`, `;`, `|`, `&`, `<`, `>`,
///   `>|`, `>>`, `(`, `)`) come back as their own tokens.
/// - **Writing** a command line from real argv, with ``quote(_:)`` matching Python's
///   `shlex.quote` byte for byte, so the Mac builds the same remote commands as Linux.
public struct RelaunchShellWords: Sendable, Equatable {
    /// One piece of shell text.
    public enum Token: Sendable, Equatable {
        /// A word, with its quoting already removed.
        case word(String)
        /// A control or redirection operator, as written.
        case op(String)
    }

    /// The tokens, in order.
    public let tokens: [Token]

    /// Tokenizes `text`.
    ///
    /// - Parameter text: Shell source. An unterminated quote makes the whole text unreadable.
    /// - Returns: `nil` when a quote is left open.
    public init?(_ text: String) {
        var tokens: [Token] = []
        var current = ""
        var inWord = false
        var characters = Array(text)[...]

        func flush() {
            if inWord { tokens.append(.word(current)) }
            current = ""
            inWord = false
        }

        while let character = characters.popFirst() {
            switch character {
            case " ", "\t", "\n", "\r":
                flush()
            case "'":
                inWord = true
                guard let end = characters.firstIndex(of: "'") else { return nil }
                current += String(characters[characters.startIndex..<end])
                characters = characters[characters.index(after: end)...]
            case "\"":
                inWord = true
                var closed = false
                while let next = characters.popFirst() {
                    if next == "\"" { closed = true; break }
                    if next == "\\", let escaped = characters.first, "$`\"\\\n".contains(escaped) {
                        characters.removeFirst()
                        if escaped != "\n" { current.append(escaped) }
                        continue
                    }
                    current.append(next)
                }
                guard closed else { return nil }
            case "\\":
                inWord = true
                if let escaped = characters.popFirst(), escaped != "\n" { current.append(escaped) }
            case "$" where characters.first == "'":
                inWord = true
                characters.removeFirst()
                var closed = false
                while let next = characters.popFirst() {
                    if next == "'" { closed = true; break }
                    if next == "\\", let escaped = characters.popFirst() {
                        switch escaped {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        default: current.append(escaped)
                        }
                        continue
                    }
                    current.append(next)
                }
                guard closed else { return nil }
            case ";", "(", ")":
                flush()
                tokens.append(.op(String(character)))
            case "&", "|", "<", ">":
                flush()
                var symbol = String(character)
                if let next = characters.first,
                   (character == "&" && next == "&") || (character == "|" && next == "|")
                    || (character == ">" && (next == ">" || next == "|")) || (character == "<" && next == "<") {
                    symbol.append(next)
                    characters.removeFirst()
                }
                tokens.append(.op(symbol))
            default:
                inWord = true
                current.append(character)
            }
        }
        flush()
        self.tokens = tokens
    }

    /// Quotes one word for a POSIX shell exactly like Python's `shlex.quote`.
    ///
    /// - Parameter word: Any text.
    /// - Returns: `''` for an empty word, the word itself when it only holds
    ///   `[A-Za-z0-9_@%+=:,./-]`, and a single-quoted word otherwise.
    public static func quote(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let safe = word.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "@", "%", "+", "=", ":", ",", ".", "/", "-": true
            default: false
            }
        }
        if safe { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Joins words into one command line, like Python's `shlex.join`.
    ///
    /// - Parameter words: The argv to join.
    /// - Returns: Each word quoted with ``quote(_:)``, separated by single spaces.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
