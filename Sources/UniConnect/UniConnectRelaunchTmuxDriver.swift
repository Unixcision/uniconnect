import CMUXAgentLaunch
import CmuxProcess
import Foundation

/// Talks to one tmux server on this machine for the relaunch flow.
///
/// Deliberately small and deliberately dumb: it reads a pane, types into a pane, and says which
/// process a pane is running. Every decision about *what* to type lives in ``RelaunchPaneSequencer``
/// and ``RelaunchAgentDialect``, where it can be tested without a terminal.
struct UniConnectRelaunchTmuxDriver: Sendable {
    private let commands: any CommandRunning
    private let executable: String
    private let processLister: String

    init(
        commands: any CommandRunning = CommandRunner(),
        executable: String = "tmux",
        processLister: String = "/usr/bin/pgrep"
    ) {
        self.commands = commands
        self.executable = executable
        self.processLister = processLister
    }

    /// The text a pane is currently showing.
    func capture(socket: String, pane: String) async -> String? {
        await run(socket: socket, ["capture-pane", "-p", "-t", pane])
    }

    /// The process a pane is running, as tmux names it (`claude.exe`, `zsh`).
    func currentCommand(socket: String, pane: String) async -> String? {
        await run(socket: socket, ["display", "-p", "-t", pane, "#{pane_current_command}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The process identifier behind a pane's shell.
    func panePID(socket: String, pane: String) async -> Int32? {
        let text = await run(socket: socket, ["display", "-p", "-t", pane, "#{pane_pid}"])
        return text.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The process actually running inside a pane, above the shell that hosts it.
    ///
    /// ``panePID(socket:pane:)`` reports the pane's **shell**, and a shell does not change when the
    /// agent running inside it is replaced — so comparing it before and after a relaunch can never
    /// prove anything, and a relaunch that worked is reported as one that failed. The agent is the
    /// shell's child, and *that* identifier does change. Nil means the pane is sitting at its shell
    /// with no agent in it, which is a reason not to close anything rather than a failure.
    func agentPID(socket: String, pane: String) async -> Int32? {
        guard let shell = await panePID(socket: socket, pane: pane) else { return nil }
        let result = await commands.run(
            directory: NSHomeDirectory(),
            executable: processLister,
            arguments: ["-P", String(shell)],
            timeout: 10
        )
        guard result.exitStatus == 0, let listing = result.stdout else { return nil }
        // The newest child: a shell that kept a stopped job around still has the live agent last.
        return listing
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .last
    }

    /// The first pane of `session`, which is the one a UniConnect window owns.
    func firstPane(socket: String, session: String) async -> String? {
        await run(socket: socket, ["list-panes", "-t", session, "-F", "#{pane_id}"])?
            .split(separator: "\n").first.map(String.init)
    }

    /// Types `text` and presses return.
    ///
    /// Sent as two calls on purpose: tmux would otherwise interpret parts of the text as key names,
    /// and a relaunch line that carries a flag is exactly the wrong place to discover that.
    func type(socket: String, pane: String, text: String) async {
        _ = await run(socket: socket, ["send-keys", "-t", pane, "--", text])
        _ = await run(socket: socket, ["send-keys", "-t", pane, "Enter"])
    }

    private func run(socket: String, _ arguments: [String]) async -> String? {
        let result = await commands.run(
            directory: NSHomeDirectory(),
            executable: executable,
            arguments: ["-L", socket] + arguments,
            timeout: 10
        )
        guard result.exitStatus == 0 else { return nil }
        return result.stdout
    }
}
