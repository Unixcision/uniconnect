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

    /// The line to type, or nil when these arguments cannot be reproduced as they were.
    ///
    /// - Parameter argv: arguments as read from the live process, already split on spaces.
    /// - Returns: a single line, each argument quoted, or nil if any argument carries shell syntax.
    static func line(from argv: [String]) -> String? {
        guard !argv.isEmpty else { return nil }
        var parts: [String] = []
        for argument in argv {
            guard !argument.isEmpty else { continue }
            // Un argumento con sintaxis de shell no se puede devolver tal cual ni con comillas: lo
            // que se leyó ya venía aplanado, así que citarlo adivinaría unos límites que no constan.
            guard argument.rangeOfCharacter(from: shellSyntax) == nil else { return nil }
            parts.append(argument)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
