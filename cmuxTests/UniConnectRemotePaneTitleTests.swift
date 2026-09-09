import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Título `comando|título` de las ventanas SSH y la línea de attach que lo activa.
@Suite("Título remoto comando|título")
struct UniConnectRemotePaneTitleTests {
    @Test("Se separa el comando del título y solo el título se enseña")
    func splitsCommandAndTitle() {
        let codex = UniConnectRemotePaneTitle(rawTitle: "codex|⠋ codex")
        #expect(codex.command == "codex")
        #expect(codex.title == "⠋ codex")
        #expect(codex.displayTitle == "⠋ codex")
        let claude = UniConnectRemotePaneTitle(rawTitle: "node|✳ Arreglar el build")
        #expect(claude.command == "node")
        #expect(claude.displayTitle == "✳ Arreglar el build")
        let shell = UniConnectRemotePaneTitle(rawTitle: "zsh|iberiavo")
        #expect(shell.command == "zsh")
        #expect(shell.displayTitle == "iberiavo")
        let nested = UniConnectRemotePaneTitle(rawTitle: "python3|a|b")
        #expect(nested.command == "python3")
        #expect(nested.title == "a|b")
    }

    @Test("Sin prefijo válido el título queda intacto")
    func leavesTitlesWithoutPrefixAlone() {
        let plain = UniConnectRemotePaneTitle(rawTitle: "✳ tema")
        #expect(plain.command == nil)
        #expect(plain.displayTitle == "✳ tema")
        let spaced = UniConnectRemotePaneTitle(rawTitle: "user | dir")
        #expect(spaced.command == nil)
        #expect(spaced.displayTitle == "user | dir")
        let empty = UniConnectRemotePaneTitle(rawTitle: "|host")
        #expect(empty.command == nil)
        #expect(empty.displayTitle == "|host")
        let emptyTitle = UniConnectRemotePaneTitle(rawTitle: "node|")
        #expect(emptyTitle.command == "node")
        #expect(emptyTitle.displayTitle == "node")
    }

    @Test("La línea de attach activa los títulos, su formato y apaga OSC 52 en un solo tmux")
    func attachCommandLinePropagatesTitles() throws {
        let create = UniConnectSSH.remoteTmuxCommand(session: "uc-1", directory: "/srv/app")
        #expect(create.hasPrefix("tmux "))
        #expect(!create.contains("; tmux "))
        #expect(create.contains("new-session -A -s 'uc-1' -c '/srv/app'"))
        #expect(create.contains("\\; set-option -g set-titles on"))
        #expect(create.contains("\\; set-option -g set-titles-string '#{pane_current_command}|#{pane_title}'"))
        #expect(create.contains("\\; set-option -s set-clipboard off"))
        let attachIndex = try #require(create.range(of: "new-session")?.lowerBound)
        let titlesIndex = try #require(create.range(of: "set-titles on")?.lowerBound)
        #expect(attachIndex < titlesIndex)

        let existing = UniConnectSSH.remoteExistingTmuxCommand(session: "uc-2")
        #expect(existing.contains("tmux set-option -g set-titles on >/dev/null 2>&1 || true;"))
        #expect(existing.contains("tmux set-option -g set-titles-string '#{pane_current_command}|#{pane_title}' >/dev/null 2>&1 || true;"))
        #expect(existing.contains("tmux set-option -s set-clipboard off >/dev/null 2>&1 || true;"))
        let optionsIndex = try #require(existing.range(of: "set-titles on")?.lowerBound)
        let execIndex = try #require(existing.range(of: "exec tmux attach-session")?.lowerBound)
        #expect(optionsIndex < execIndex)

        let recoverable = UniConnectSSH.remoteRecoverableTmuxCommand(session: "uc-3", directory: "/gone")
        #expect(recoverable.contains("else tmux set-option -g set-titles on \\; set-option -g set-titles-string '#{pane_current_command}|#{pane_title}' \\; set-option -s set-clipboard off \\; attach-session -t '=uc-3';"))

        let line = try #require(UniConnectSSH.attachCommandLine(
            connectCommand: "ssh root@1.2.3.4",
            session: "uc-4",
            directory: nil
        ))
        #expect(line.contains("set-titles on"))
        #expect(line.contains("pane_current_command}|#{pane_title}"))
        #expect(line.contains("set-clipboard off"))
    }
}
