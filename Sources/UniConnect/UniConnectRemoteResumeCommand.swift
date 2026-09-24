import CMUXAgentLaunch
import Foundation

/// The command a missing remote tmux session is recreated with, so its agent comes back.
///
/// It is handed to `tmux new-session -A` as the pane's command. tmux only runs it when it creates
/// the session; with `-A` and the session alive it just attaches and ignores it. The command:
///
/// 1. changes to the agent's folder and runs the shared open-conversation guard
///    (`agent_guard.py`, sent inline as base64) for that provider and conversation;
/// 2. only when the guard says the conversation is free (exit 0) resumes it without questions
///    (`IS_SANDBOX=1` for Claude as root), from the shared `noPrompt` policy;
/// 3. otherwise prints a Spanish notice; either way it ends in a login shell.
///
/// It never contains `$` (it crosses Swift, ssh, the remote shell and tmux) and never ends in
/// `;` (tmux would read that as a command separator). Without `python3` on the host there is no
/// guard, so nothing is resumed and the notice is shown.
struct UniConnectRemoteResumeCommand {
    /// Builds the recreate-and-resume command for one window.
    ///
    /// - Parameters:
    ///   - record: The window's verified remote agent.
    ///   - sshUser: The SSH user, used for `IS_SANDBOX` when the record does not say whether the
    ///     agent ran as root.
    ///   - guardSource: The text of `agent_guard.py`.
    ///   - policy: The shared no-prompt policy.
    /// - Returns: The command, or `nil` when the window was not running an agent, lacks a
    ///   conversation or folder, or the guard or policy is unavailable.
    func line(
        record: UniConnectRemoteAgentRecord,
        sshUser: String?,
        guardSource: String?,
        policy: AgentNoPromptPolicy?
    ) -> String? {
        guard record.runtimeState == .agent,
              let sessionID = record.sessionID, AgentNoPromptPolicy.isValidSessionID(sessionID),
              let directory = record.workingDirectory, directory.hasPrefix("/"),
              let guardSource, !guardSource.isEmpty,
              let policy else { return nil }
        let asRoot = record.asRoot ?? (sshUser == "root")
        guard let resume = policy.resume(provider: record.provider, sessionID: sessionID, asRoot: asRoot) else {
            return nil
        }
        let wireProvider = policy.wireProvider(record.provider)
        let encodedGuard = Data(guardSource.utf8).base64EncodedString()
        let notice = String(
            localized: "uniconnect.ssh.resume.guardRefused",
            defaultValue: "[UniConnect] No se reanuda: la conversación sigue abierta en otra ventana o falta la carpeta."
        )
        let line = [
            "if cd --", UniConnectSSH.shellQuote(directory),
            "&& python3 -c 'import base64,sys;s=sys.argv.pop(1);exec(base64.b64decode(s))'",
            encodedGuard, UniConnectSSH.shellQuote(wireProvider), UniConnectSSH.shellQuote(sessionID) + ";",
            "then", resume.shellLine(workingDirectory: nil) + ";",
            "else printf '%s\\n'", UniConnectSSH.shellQuote(notice) + ";",
            "fi; exec bash -l || exec sh -l",
        ].joined(separator: " ")
        guard !line.contains("$"), !line.hasSuffix(";"), !line.contains("\n") else { return nil }
        return line
    }

    /// The directory and command a restore or reconnect passes to the recoverable tmux command.
    ///
    /// - Parameters:
    ///   - record: The window's saved remote agent, if any.
    ///   - sshUser: The SSH user of the box.
    ///   - autoResumeEnabled: The «reanudar IA al abrir» setting.
    ///   - guardSource: The text of `agent_guard.py` (bundled from `linux/uniconnect/`).
    ///   - policy: The shared no-prompt policy.
    /// - Returns: `nil` when nothing should be resumed; the restore then keeps today's behaviour.
    func startup(
        record: UniConnectRemoteAgentRecord?,
        sshUser: String?,
        autoResumeEnabled: Bool = AgentSessionAutoResumeSettings.isEnabled(),
        guardSource: String? = UniConnectRemoteAgentProbe.bundledScript(named: "agent_guard"),
        policy: AgentNoPromptPolicy? = try? AgentNoPromptPolicy()
    ) -> (directory: String, initialCommand: String)? {
        guard autoResumeEnabled, let record, let directory = record.workingDirectory,
              let command = line(record: record, sshUser: sshUser, guardSource: guardSource, policy: policy) else {
            return nil
        }
        return (directory, command)
    }
}
