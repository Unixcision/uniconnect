import Foundation

/// How Claude Code is read and relaunched.
///
/// Every rule here was paid for by doing it by hand to 26 windows: `Ctrl+C` does not close it,
/// `/exit` does; the option in its background-work question is found by wording because its position
/// moves; and the identifier worth resuming is the one it prints on the way out, because the
/// arguments a pane was started with can be silent about which conversation it is on.
public struct ClaudeRelaunchDialect: RelaunchAgentDialect {
    public let provider = "claude"

    public init() {}

    public func read(screen: String) -> RelaunchScreenReading {
        RelaunchScreenReading.read(screen: screen)
    }

    public func relaunchCommand(sessionID: String?, previousArguments: [String]) -> String? {
        // Without a conversation to name there is nothing safe to do: `--continue` would take
        // whichever session in that folder was touched last, and several windows share a folder.
        guard let sessionID, !sessionID.isEmpty else { return nil }
        var command = ["claude", "--resume", sessionID]
        // Flags come back exactly as they were. Relaunching is not the moment to change how an
        // agent is allowed to behave.
        if previousArguments.contains("--dangerously-skip-permissions") {
            command.append("--dangerously-skip-permissions")
        }
        return command.joined(separator: " ")
    }
}
