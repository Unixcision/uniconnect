import Foundation

/// How an adapter closes its agent before bringing the same conversation back.
///
/// Two agents, two life cycles. Claude is walked out step by step from what its screen shows and
/// prints its conversation on the way out. Codex prints nothing worth trusting: its conversation has
/// to be proven **before** anything is closed, the exit command is typed without pressing return,
/// return is pressed only once the command is seen on the composer line, and then the process is
/// waited for — never killed.
public enum RelaunchClosing: Sendable, Equatable {
    /// Read the screen and follow ``RelaunchPaneSequencer`` step by step (Claude).
    case sequenced
    /// Only with an empty composer: type `command` literally, see it on the cursor line, press
    /// return, and wait for the process to end on its own (Codex). The conversation must be proven
    /// beforehand, because the agent does not print it.
    case confirmedCommand(String)
}
