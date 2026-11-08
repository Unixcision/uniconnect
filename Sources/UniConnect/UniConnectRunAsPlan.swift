import Foundation

/// What a new window runs once it is the right user (`run-as.v1`): folder, `IS_SANDBOX` and the
/// agent with its no-prompt policy, then that user's shell.
///
/// With a switch, ``innerCommand`` is the `<orden>` handed to the shared wrapper `subir.sh`,
/// which runs it only after `id -un` confirms the user. Without one (`current`), ``launchLine``
/// runs as is: `current` never goes through the wrapper.
struct UniConnectRunAsPlan: Equatable, Sendable {
    let runAs: UniConnectRunAs
    /// Folder to move to; `nil` keeps where the shell starts.
    let workingDirectory: String?
    /// `export IS_SANDBOX=1` before the agent.
    let isSandbox: Bool
    /// The agent with its no-prompt policy; `nil` for a plain shell.
    let agentArgv: [String]?

    /// `cd`, `IS_SANDBOX` and the agent, or `nil` when there is nothing to run.
    var launchLine: String? {
        var parts: [String] = []
        if let workingDirectory { parts.append("cd -- " + TerminalStartupShellQuoting.singleQuoted(workingDirectory)) }
        if isSandbox, agentArgv != nil { parts.append("export IS_SANDBOX=1") }
        if let agentArgv, !agentArgv.isEmpty {
            parts.append(agentArgv.map(TerminalStartupShellQuoting.singleQuoted).joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// The wrapper's `<orden>`: the launch, then the target user's own shell.
    var innerCommand: String {
        (launchLine.map { $0 + "; " } ?? "") + "exec \"${SHELL:-/bin/sh}\" -l"
    }
}
