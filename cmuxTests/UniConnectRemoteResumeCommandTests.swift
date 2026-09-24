import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Recrear una sesión tmux remota caída trae su IA de vuelta sin preguntas, con la guarda delante.
@Suite("UniConnect: reanudar la IA de una caja SSH al recrear su tmux")
struct UniConnectRemoteResumeCommandTests {
    private let claudeID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
    private let codexID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"
    private let guardSource = "import sys\nsys.exit(0)\n"

    private func record(
        _ provider: String, _ id: String, cwd: String = "/root/xunis", asRoot: Bool? = true
    ) throws -> UniConnectRemoteAgentRecord {
        try #require(UniConnectRemoteAgentRecord(
            observing: .init(provider: provider, sessionID: id, workingDirectory: cwd, asRoot: asRoot, source: "ficha"),
            tmuxSocket: "default",
            at: 1
        ))
    }

    @Test("Claude como root se reanuda con IS_SANDBOX y sin preguntas, detrás de la guarda")
    func claudeAsRoot() throws {
        let line = try #require(UniConnectRemoteResumeCommand().line(
            record: record("claude", claudeID), sshUser: "root", guardSource: guardSource,
            policy: try AgentNoPromptPolicy()
        ))
        #expect(line.hasPrefix("if cd -- '/root/xunis' && python3 -c "))
        #expect(line.contains("then IS_SANDBOX=1 claude --resume \(claudeID) --dangerously-skip-permissions;"))
        #expect(line.contains(Data(guardSource.utf8).base64EncodedString()))
        #expect(line.contains("'claude' '\(claudeID)'"))
        #expect(line.hasSuffix("exec bash -l || exec sh -l"))
        #expect(!line.contains("$"))
        #expect(!line.hasSuffix(";"))
    }

    @Test("Sin dato de root decide el usuario ssh")
    func rootFromSSHUser() throws {
        let policy = try AgentNoPromptPolicy()
        let unknown = try record("claude", claudeID, asRoot: nil)
        let asRoot = try #require(UniConnectRemoteResumeCommand().line(
            record: unknown, sshUser: "root", guardSource: guardSource, policy: policy
        ))
        #expect(asRoot.contains("IS_SANDBOX=1 claude"))
        let asUser = try #require(UniConnectRemoteResumeCommand().line(
            record: unknown, sshUser: "dani", guardSource: guardSource, policy: policy
        ))
        #expect(!asUser.contains("IS_SANDBOX"))
    }

    @Test("Codex se reanuda con --yolo tras el ejecutable")
    func codex() throws {
        let line = try #require(UniConnectRemoteResumeCommand().line(
            record: record("codex", codexID, cwd: "/root/scrapper"), sshUser: "root",
            guardSource: guardSource, policy: try AgentNoPromptPolicy()
        ))
        #expect(line.contains("then codex --yolo resume \(codexID);"))
        #expect(!line.contains("IS_SANDBOX"))
    }

    @Test("Un shell, sin guarda, sin política o sin id no se reanuda")
    func nothingToResume() throws {
        let policy = try AgentNoPromptPolicy()
        var shell = try record("claude", claudeID)
        _ = shell.observeShell(at: 2)
        let active = try record("claude", claudeID)
        let command = UniConnectRemoteResumeCommand()
        let fromShell = command.line(record: shell, sshUser: "root", guardSource: guardSource, policy: policy)
        #expect(fromShell == nil)
        let withoutGuard = command.line(record: active, sshUser: "root", guardSource: nil, policy: policy)
        #expect(withoutGuard == nil)
        let withoutPolicy = command.line(record: active, sshUser: "root", guardSource: guardSource, policy: nil)
        #expect(withoutPolicy == nil)
        let disabled = command.startup(
            record: active, sshUser: "root", autoResumeEnabled: false, guardSource: guardSource, policy: policy
        )
        #expect(disabled?.initialCommand == nil)
        let missing = command.startup(record: nil, sshUser: "root", autoResumeEnabled: true, guardSource: guardSource, policy: policy)
        #expect(missing?.initialCommand == nil)
        let enabled = try #require(command.startup(
            record: active, sshUser: "root", autoResumeEnabled: true, guardSource: guardSource, policy: policy
        ))
        #expect(enabled.directory == "/root/xunis")
    }

    @Test("Una carpeta con $ no se reanuda: la orden nunca lleva $")
    func dollarIsRefused() throws {
        let withDollar = try record("claude", claudeID, cwd: "/root/$HOME")
        let line = UniConnectRemoteResumeCommand().line(
            record: withDollar, sshUser: "root", guardSource: guardSource, policy: try AgentNoPromptPolicy()
        )
        #expect(line == nil)
    }

    @Test("Sin orden inicial el comando tmux es el de siempre; con ella, va tras -s y -c")
    func tmuxCommandIsUnchangedWithoutInitialCommand() {
        let base = UniConnectSSH.remoteTmuxCommand(session: "claudebets", directory: "/root/xunis")
        #expect(base == UniConnectSSH.remoteTmuxCommand(session: "claudebets", directory: "/root/xunis", initialCommand: nil))
        #expect(base.hasPrefix("tmux set-option -g history-limit 50000 \\; new-session -A -s 'claudebets' -c '/root/xunis' \\; "))
        let withCommand = UniConnectSSH.remoteTmuxCommand(
            session: "claudebets", directory: "/root/xunis", initialCommand: "echo 'hola'"
        )
        #expect(withCommand == base.replacingOccurrences(
            of: "-c '/root/xunis' \\;",
            with: "-c '/root/xunis' 'echo '\\''hola'\\''' \\;"
        ))
        #expect(UniConnectSSH.remoteRecoverableTmuxCommand(session: "claudebets", directory: nil)
            == UniConnectSSH.remoteRecoverableTmuxCommand(session: "claudebets", directory: nil, initialCommand: nil))
    }
}
