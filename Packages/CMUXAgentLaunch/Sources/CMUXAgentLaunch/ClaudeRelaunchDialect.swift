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
        var argv = ["claude", "--resume", conversation]
        // Flags come back exactly as they were. Relaunching is not the moment to change what an
        // agent is allowed to do, in either direction.
        if previousArgv.contains("--dangerously-skip-permissions") {
            argv.append("--dangerously-skip-permissions")
        }
        return argv
    }
}
