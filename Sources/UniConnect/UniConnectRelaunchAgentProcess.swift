import Foundation

/// The agent process occupying a pane, identified well enough to prove it was replaced.
///
/// A process identifier alone is not enough: the kernel reuses them, so a pane whose agent died and
/// whose number was handed to something else would read as the same agent still running. The start
/// time is carried alongside precisely so that cannot happen.
struct UniConnectRelaunchAgentProcess: Equatable, Sendable {
    /// The identifier of the live agent process.
    let pid: Int32
    /// When the system says that process began, compared verbatim and never parsed.
    let startedAt: String

    /// Whether this is the same live process as `other`, identifier and start time together.
    ///
    /// The pair is the identity. A bare identifier answers this wrongly twice over: a pane's shell
    /// keeps its number across a relaunch that worked, and the kernel reuses a number after a
    /// relaunch that did not. Nothing is hashed on the way — a hash can collide, and a collision
    /// here reads as "the agent was never replaced" on a relaunch that replaced it.
    func isSameProcess(as other: UniConnectRelaunchAgentProcess) -> Bool {
        self == other
    }
}

/// What was found when looking for the agent inside a pane.
///
/// Four answers and not an optional, because "there is no agent here" and "the machine did not
/// answer" lead to opposite decisions: the first is a reason to leave a window alone, the second is
/// a reason to stop. Collapsing them into `nil` is how a read failure turns into a closed agent.
enum UniConnectRelaunchAgentLookup: Equatable, Sendable {
    /// Exactly one process of the expected provider runs under the pane.
    case found(UniConnectRelaunchAgentProcess)
    /// The pane is sitting at its shell. There is nothing to close.
    case noAgent
    /// More than one candidate, and nothing here says which is the agent. Never guessed.
    case ambiguous
    /// The process table or tmux could not be read. Nothing is known, so nothing is done.
    case unreadable
}
