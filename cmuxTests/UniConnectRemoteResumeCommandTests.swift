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

    /// La línea de dentro de `/bin/sh -c '…'`, deshaciendo el entrecomillado simple POSIX.
    private func inner(_ line: String) throws -> String {
        let prefix = "/bin/sh -c '"
        #expect(line.hasPrefix(prefix))
        #expect(line.hasSuffix("'"))
        let quoted = try #require(line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count).dropLast()) : nil)
        return quoted.replacingOccurrences(of: #"'\''"#, with: "'")
    }

    @Test("Claude como root se reanuda con IS_SANDBOX y sin preguntas, detrás de la guarda")
    func claudeAsRoot() throws {
        let line = try #require(UniConnectRemoteResumeCommand().line(
            record: try record("claude", claudeID), sshUser: "root", guardSource: guardSource,
            policy: try AgentNoPromptPolicy()
        ))
        // Va entera dentro de /bin/sh -c: el default-shell del VPS puede ser fish o tcsh.
        let body = try inner(line)
        #expect(body.hasPrefix("if cd -- '/root/xunis' && python3 -c "))
        #expect(body.contains("then IS_SANDBOX=1 claude --resume \(claudeID) --dangerously-skip-permissions;"))
        #expect(body.contains(Data(guardSource.utf8).base64EncodedString()))
        #expect(body.contains("'claude' '\(claudeID)'"))
        #expect(body.hasSuffix("fi; command -v bash >/dev/null && exec bash -l; exec sh -l"))
        #expect(UniConnectSSH.shellQuote(body) == String(line.dropFirst("/bin/sh -c ".count)))
        #expect(!line.contains("$"))
        #expect(!line.hasSuffix(";"))
    }

    @Test("La orden se ejecuta con /bin/sh aunque el shell de quien la lanza no sea POSIX")
    func runsUnderPOSIXShell() async throws {
        // Una guarda que dice «libre» y un ejecutable falso de Claude que apunta su argv.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-remote-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trace = folder.appendingPathComponent("trace")
        for (name, body) in [
            ("claude", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$UC_TRACE\"\n"),
            ("python3", "#!/bin/sh\nexit 0\n"),
            ("bash", "#!/bin/sh\nexit 0\n"),
        ] {
            let url = folder.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let line = try #require(UniConnectRemoteResumeCommand().line(
            record: try record("claude", claudeID, cwd: folder.path, asRoot: false), sshUser: "dani",
            guardSource: guardSource, policy: try AgentNoPromptPolicy()
        ))
        // tmux lo pasa a `default-shell -c`; aquí, a un sh cualquiera.
        let invocation = try #require(UniConnectSSHProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", line],
            environment: ["PATH": folder.path + ":/usr/bin:/bin", "UC_TRACE": trace.path]
        ))
        try await UniConnectSSHCommandService().execute(invocation, timeout: .seconds(5))
        let argv = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv == ["--resume", claudeID, "--dangerously-skip-permissions"])
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
            record: try record("codex", codexID, cwd: "/root/scrapper"), sshUser: "root",
            guardSource: guardSource, policy: try AgentNoPromptPolicy()
        ))
        let body = try inner(line)
        #expect(body.contains("then codex --yolo resume \(codexID);"))
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
            record: active, sshUser: "root", seenLiveRecently: true, autoResumeEnabled: false,
            guardSource: guardSource, policy: policy
        )
        #expect(disabled?.initialCommand == nil)
        let missing = command.startup(
            record: nil, sshUser: "root", seenLiveRecently: true, autoResumeEnabled: true,
            guardSource: guardSource, policy: policy
        )
        #expect(missing?.initialCommand == nil)
        // D6: sin una lectura en vivo reciente (o tras un cierre deliberado) no se reanuda sola.
        let notSeen = command.startup(
            record: active, sshUser: "root", seenLiveRecently: false, autoResumeEnabled: true,
            guardSource: guardSource, policy: policy
        )
        #expect(notSeen?.initialCommand == nil)
        let enabled = try #require(command.startup(
            record: active, sshUser: "root", seenLiveRecently: true, autoResumeEnabled: true,
            guardSource: guardSource, policy: policy
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
