import CMUXAgentLaunch
import Foundation

/// What a relaunch needs from the terminal a window lives in.
///
/// Narrow on purpose: read a pane, type into a pane, and say which agent is in it. Every decision
/// about *what* to type lives above this, which is why the seam is here — a relaunch that closes an
/// agent and then reports the wrong thing is a bug in the sequence, not in tmux, and a test should
/// be able to reach it without a terminal.
protocol UniConnectRelaunchPaneAccess: Sendable {
    /// The first pane of `session`, which is the one a UniConnect window owns.
    func firstPane(socket: String, session: String) async -> String?
    /// The process identifier behind a pane's shell, used only to tell a live pane from a gone one.
    func panePID(socket: String, pane: String) async -> Int32?
    /// The agent of `provider` running under the pane, or why it could not be established.
    func agent(socket: String, pane: String, provider: String) async -> UniConnectRelaunchAgentLookup
    /// The text a pane is currently showing.
    func capture(socket: String, pane: String) async -> String?
    /// Types `text` into the pane and presses return.
    func type(socket: String, pane: String, text: String) async

    /// The pane's text with its cursor and styling, for agents whose composer needs them (Codex).
    func screen(socket: String, pane: String) async -> RelaunchPaneScreen?
    /// Types `text` literally, **without** pressing return.
    func typeLiteral(socket: String, pane: String, text: String) async
    /// Presses return on its own.
    func pressEnter(socket: String, pane: String) async
    /// Presses Escape, to back out of a question without answering it.
    func pressEscape(socket: String, pane: String) async
    /// Whether the pane's foreground process is its shell again.
    func isAtShell(socket: String, pane: String) async -> Bool
}

extension UniConnectRelaunchPaneAccess {
    /// A pane access that cannot read cursors never lets a confirmed close start.
    func screen(socket: String, pane: String) async -> RelaunchPaneScreen? { nil }
    /// Nothing is typed by a pane access that does not implement literal typing.
    func typeLiteral(socket: String, pane: String, text: String) async {}
    /// Nothing is pressed by a pane access that does not implement it.
    func pressEnter(socket: String, pane: String) async {}
    /// Nothing is pressed by a pane access that does not implement it.
    func pressEscape(socket: String, pane: String) async {}
    /// Unknown counts as "not at the shell", so nothing is typed.
    func isAtShell(socket: String, pane: String) async -> Bool { false }
}

extension UniConnectRelaunchTmuxDriver: UniConnectRelaunchPaneAccess {}
