import Foundation

/// Turns the arguments read off a live process back into one line a shell will run verbatim.
///
/// Typing a relaunch into a pane means handing text to a shell, so every argument that came back
/// from `ps` is about to be re-parsed by one. Joining them with spaces — which is what this replaced
/// — lets a `;`, a `$(…)` or a quote inside somebody's prompt stop being data and start being
/// syntax. Conserving *more* of the original command line made that worse, not better: before, only
/// one known flag was kept and there was nothing to inject through.
///
/// `ps` also cannot be un-parsed. It prints the arguments already joined, so `--flag "a b"` and
/// `--flag a b` arrive identical and no amount of care recovers which one it was. That is why this
/// can **refuse**: a window whose launch cannot be reproduced faithfully is left alone and said so,
/// rather than relaunched into something subtly different.
struct UniConnectRelaunchCommandLine {
    /// Characters that stop being themselves once a shell reads them.
    private static let shellSyntax = CharacterSet(charactersIn: ";|&$`()<>\n\r\t\\\"'*?[]{}~#!")

    /// Options whose value is a single self-describing token, safe to carry across a relaunch.
    ///
    /// A closed list, and short on purpose. It is not a catalogue of everything an agent accepts —
    /// it is the set of things that survive `ps` without ambiguity.
    private static let optionsTakingOneValue: Set<String> = [
        "--resume", "-r", "--model", "--add-dir", "--settings", "--permission-mode",
    ]

    /// Options whose value is free text, which `ps` cannot give back intact.
    private static let optionsTakingFreeText: Set<String> = [
        "--append-system-prompt", "--system-prompt", "--prompt", "-p",
    ]

    /// The line to type, or nil when these arguments cannot be reproduced as they were.
    ///
    /// Refuses on anything it cannot account for. `ps` prints the arguments already joined, so a
    /// single value of `"hola --dangerously-skip-permissions"` arrives as three tokens and the
    /// middle one would come back as a **real permission** — no shell metacharacter in sight, and
    /// checking for those does not catch it. The only honest answer to a command line that cannot
    /// be un-flattened is to leave that window alone.
    ///
    /// - Parameter argv: arguments as read from the live process, already split on spaces.
    /// - Returns: a single line, or nil if these arguments cannot be accounted for one by one.
    static func line(from argv: [String]) -> String? {
        guard let executable = argv.first, !executable.isEmpty else { return nil }
        guard argv.allSatisfy({ $0.rangeOfCharacter(from: shellSyntax) == nil }) else { return nil }

        var parts: [String] = [executable]
        var index = argv.index(after: argv.startIndex)
        while index < argv.endIndex {
            let argument = argv[index]
            index = argv.index(after: index)
            guard !argument.isEmpty else { continue }

            // Texto libre: lo que sigue puede ser una palabra o veinte, y no hay forma de saberlo.
            if optionsTakingFreeText.contains(argument) { return nil }
            if optionsTakingFreeText.contains(where: { argument.hasPrefix($0 + "=") }) { return nil }

            if optionsTakingOneValue.contains(argument) {
                guard index < argv.endIndex else { return nil }
                let value = argv[index]
                // Un valor que parece una opción es la señal de que el anterior se quedó sin la
                // suya, o de que este trozo era parte de un texto más largo.
                guard !value.hasPrefix("-") else { return nil }
                parts.append(argument)
                parts.append(value)
                index = argv.index(after: index)
                continue
            }

            // Cualquier otra cosa solo se conserva si es una opción por sí sola. Una palabra suelta
            // es, casi siempre, el resto de un valor que `ps` aplanó.
            guard argument.hasPrefix("-") else { return nil }
            parts.append(argument)
        }
        return parts.joined(separator: " ")
    }

    /// Whether `argv` names `conversation` as the value of its resume option.
    ///
    /// Not `contains`: an identifier mentioned anywhere — inside a prompt, in a path — would pass
    /// that while the agent resumed something else entirely. The only thing that answers "which
    /// conversation is this process on" is the value attached to the option that selects it.
    static func resumes(_ conversation: String, in argv: [String]) -> Bool {
        var index = argv.startIndex
        while index < argv.endIndex {
            let argument = argv[index]
            if argument == "--resume" || argument == "-r" {
                let value = argv.index(after: index)
                return value < argv.endIndex && argv[value] == conversation
            }
            if argument.hasPrefix("--resume=") {
                return String(argument.dropFirst("--resume=".count)) == conversation
            }
            index = argv.index(after: index)
        }
        return false
    }
}
