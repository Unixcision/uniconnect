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
    /// The command line the agent is actually running under, read from the live process.
    ///
    /// Read **before** anything is closed, because afterwards there is nothing left to ask. This is
    /// what makes a relaunch give back the same agent rather than a similar one: the flags a window
    /// was opened with are not in any record — measured on this desktop, every window had
    /// `--dangerously-skip-permissions` and the inventory knew about none of them. Reopening
    /// without them would quietly take away what an agent is allowed to do.
    let argv: [String]

    /// Whether this is the same live process as `other`, identifier and start time together.
    ///
    /// The pair is the identity. A bare identifier answers this wrongly twice over: a pane's shell
    /// keeps its number across a relaunch that worked, and the kernel reuses a number after a
    /// relaunch that did not. Nothing is hashed on the way — a hash can collide, and a collision
    /// here reads as "the agent was never replaced" on a relaunch that replaced it.
    func isSameProcess(as other: UniConnectRelaunchAgentProcess) -> Bool {
        self == other
    }

    /// Dos lecturas son del mismo proceso cuando coinciden identificador y arranque.
    ///
    /// Escrita a mano y **sin `argv`** a propósito. La igualdad sintetizada lo incluía en cuanto se
    /// añadió, y entonces dos lecturas del mismo proceso con la línea de comandos leída de forma
    /// distinta contaban como reemplazo: un «verificado» sobre un relanzado que nunca ocurrió. La
    /// línea de comandos es un dato del proceso, no lo que lo distingue de otro.
    static func == (lhs: UniConnectRelaunchAgentProcess, rhs: UniConnectRelaunchAgentProcess) -> Bool {
        lhs.pid == rhs.pid && lhs.startedAt == rhs.startedAt
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
