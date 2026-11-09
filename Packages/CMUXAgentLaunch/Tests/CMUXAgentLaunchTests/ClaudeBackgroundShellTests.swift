import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Los monitores son los envoltorios de Bash de Claude; lo que se guarda es su orden exacta.
@Suite("Monitores y shells de fondo de Claude")
struct ClaudeBackgroundShellTests {
    @Test("El envoltorio de Linux con -c -l: se extrae la orden y el fichero del scratchpad")
    func linuxWrapper() throws {
        let shell = try #require(ClaudeBackgroundShell(argv: [
            "/bin/bash", "-c", "-l",
            #"shopt -u extglob 2>/dev/null || true && { \builtin unalias -- 'unsetenv'; \builtin unset -f -- 'unsetenv'; } >/dev/null 2>&1 || true && eval 'bash /tmp/claude-0/x/scratchpad/monitor_poll.sh' < /dev/null && pwd -P >| /tmp/claude-1a2b-cwd"#,
        ]))
        #expect(shell.command == "bash /tmp/claude-0/x/scratchpad/monitor_poll.sh")
        #expect(shell.referencedFiles == ["/tmp/claude-0/x/scratchpad/monitor_poll.sh"])
    }

    @Test("El envoltorio del Mac con shell-snapshots y comillas dentro de la orden")
    func macSnapshotWrapper() throws {
        let script = #"source /Users/d/.claude/shell-snapshots/snapshot-zsh-1794255914513-yuxmjj.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'tail -n0 -F /tmp/uc-prueba.log | grep --line-buffered '\''HOLA'\''' < /dev/null && pwd -P >| /private/tmp/claude-501/-Users-d/abc/scratchpad/../cwd"#
        let shell = try #require(ClaudeBackgroundShell(argv: ["/bin/zsh", "-c", script]))
        #expect(shell.command == "tail -n0 -F /tmp/uc-prueba.log | grep --line-buffered 'HOLA'")
        #expect(shell.referencedFiles.isEmpty)
    }

    @Test("Ficheros de /private/tmp/claude-<uid> también, sin repetir")
    func privateTmpFiles() throws {
        let shell = try #require(ClaudeBackgroundShell(argv: [
            "bash", "-l", "-c",
            "{ unalias -- 'unsetenv'; } && eval 'python3 /private/tmp/claude-501/p/s/scratchpad/w.py --log /private/tmp/claude-501/p/s/scratchpad/w.py'",
        ]))
        #expect(shell.referencedFiles == ["/private/tmp/claude-501/p/s/scratchpad/w.py"])
    }

    @Test("Un servidor MCP, una orden sin eval o sin prólogo de Claude no son monitores", arguments: [
        ["node", "/usr/lib/node_modules/@playwright/mcp/cli.js"],
        ["/bin/bash", "-c", "tail -F /var/log/syslog"],
        ["/bin/bash", "-c", "eval 'tail -F /var/log/syslog'"],
        ["python3", "-c", "{ unalias -- 'unsetenv'; } && eval 'x'"],
        ["/bin/bash", "-c", "{ unalias -- 'unsetenv'; } && eval 'sin cerrar"],
    ])
    func othersAreNotMonitors(_ argv: [String]) {
        #expect(ClaudeBackgroundShell(argv: argv) == nil)
    }
}
