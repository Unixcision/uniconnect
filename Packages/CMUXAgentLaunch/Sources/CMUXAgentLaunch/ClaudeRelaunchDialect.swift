import Foundation

/// How Claude Code is read, identified and relaunched.
///
/// Paid for by doing it by hand to 26 windows: `Ctrl+C` does not close it and `/exit` does; the
/// option in its background-work question is found by wording because its position moves; and the
/// identifier worth resuming is the one it prints on the way out, because the arguments a pane was
/// started with can be silent about which conversation it ended up on — 5 of those 26 had no
/// `--resume` at all.
public struct ClaudeRelaunchDialect: RelaunchAgentDialect {
    public let provider = "claude"

    public init() {}

    public func read(screen: String) -> RelaunchScreenReading {
        RelaunchScreenReading.read(screen: screen)
    }

    public func conversation(from evidence: RelaunchIdentityEvidence) -> String? {
        evidence.provenConversation
    }

    public func invocation(conversation: String, previousArgv: [String]) -> [String]? {
        guard !conversation.isEmpty else { return nil }

        // Everything the window was opened with comes back, not a chosen few. Keeping only the
        // permission flag looked safe and was not: a window opened with `--model` or an appended
        // system prompt would come back as a different agent wearing the same name. Measured on one
        // desktop, 25 of 27 windows carried exactly one flag — and the exceptions are the point.
        var argv = ["claude", "--resume", conversation]
        var rest = previousArgv.dropFirst()  // el ejecutable lo pone esta invocacion

        // La seleccion de conversacion se sustituye por la pedida, venga como venga expresada:
        // `--continue` y `--resume <otra>` son las dos formas de decir «sigue con aquella», y las
        // dos tienen que dejar paso a la que se acaba de acreditar.
        var kept: [String] = []
        var index = rest.startIndex
        while index < rest.endIndex {
            let argument = rest[index]
            if argument == "--continue" || argument == "-c" {
                index = rest.index(after: index)
                continue
            }
            if argument == "--resume" || argument == "-r" {
                index = rest.index(after: index)
                // Su valor, si lo trae, se va con ella.
                if index < rest.endIndex, !rest[index].hasPrefix("-") {
                    index = rest.index(after: index)
                }
                continue
            }
            kept.append(argument)
            index = rest.index(after: index)
        }
        argv.append(contentsOf: kept)
        rest = ArraySlice(kept)
        return argv
    }
}
