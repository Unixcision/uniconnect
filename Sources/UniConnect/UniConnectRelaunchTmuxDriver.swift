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
        processLister: String = "/bin/ps"
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

    /// Finds the agent of `provider` running under a pane, or says why it could not.
    ///
    /// ``panePID(socket:pane:)`` reports the pane's **shell**, and a shell does not change when the
    /// agent inside it is replaced — so comparing it before and after a relaunch can never prove
    /// anything, and a relaunch that worked is reported as one that failed.
    ///
    /// The agent is not simply "the shell's child" either. A wrapper makes it a grandchild, and a
    /// background job makes it one candidate among several, so the whole subtree is walked and only
    /// an executable named after the provider counts. **Exactly one match is required**: several
    /// candidates with nothing to tell them apart is `ambiguous`, never a guess, because guessing
    /// here means closing an agent that was doing something else.
    func agent(
        socket: String,
        pane: String,
        provider: String
    ) async -> UniConnectRelaunchAgentLookup {
        guard let shell = await panePID(socket: socket, pane: pane) else { return .unreadable }
        guard let table = await processTable() else { return .unreadable }

        // El shell que dice tmux tiene que estar en la tabla. Si no esta, lo que falla es la
        // correspondencia entre las dos lecturas, y recorrer un arbol que no contiene la raiz
        // devuelve «aqui no hay IA» sobre una ventana de la que no sabemos nada.
        guard table.contains(where: { $0.pid == shell }) else { return .unreadable }

        var childrenByParent: [Int32: [Int32]] = [:]
        for row in table { childrenByParent[row.parent, default: []].append(row.pid) }

        // La raiz cuenta: un panel cuyo shell hizo `exec` del agente lo tiene como raiz, y dejarla
        // fuera devolveria «aqui no hay IA» sobre una ventana que si la tiene.
        var subtree: [Int32] = [shell]
        var frontier = childrenByParent[shell] ?? []
        while let next = frontier.popLast() {
            guard !subtree.contains(next) else { continue }  // un ciclo no deberia existir; no colgarse si lo hay
            subtree.append(next)
            frontier.append(contentsOf: childrenByParent[next] ?? [])
        }

        let names = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0.command) })
        let matches = subtree.filter { pid in
            guard let command = names[pid] else { return false }
            return Self.executableName(of: command) == provider
        }
        guard matches.count == 1, let pid = matches.first else {
            return matches.isEmpty ? .noAgent : .ambiguous
        }
        guard let startedAt = await startTime(of: pid),
              let argv = await commandLine(of: pid) else { return .unreadable }
        return .found(.init(pid: pid, startedAt: startedAt, argv: argv))
    }

    /// Every live process as (pid, parent, command), or nil when the table could not be read.
    private func processTable() async -> [(pid: Int32, parent: Int32, command: String)]? {
        let result = await commands.run(
            directory: NSHomeDirectory(),
            executable: processLister,
            arguments: ["-Ao", "pid=,ppid=,comm="],
            timeout: 10
        )
        guard result.exitStatus == 0, let listing = result.stdout else { return nil }
        var rows: [(pid: Int32, parent: Int32, command: String)] = []
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else {
                // Una fila que no se entiende hace sospechosa la tabla entera: descartarla en
                // silencio convierte una lectura incompleta en «no hay agente», y eso decide
                // cerrar o no cerrar. Mejor no saber nada que saber mal.
                return nil
            }
            rows.append((pid, parent, String(fields[2]).trimmingCharacters(in: .whitespaces)))
        }
        // Una tabla vacia no es un sistema sin procesos: es una lectura que no sirvio.
        return rows.isEmpty ? nil : rows
    }

    /// When the system says a process started. Compared verbatim, never parsed.
    private func startTime(of pid: Int32) async -> String? {
        let result = await commands.run(
            directory: NSHomeDirectory(),
            executable: processLister,
            arguments: ["-o", "lstart=", "-p", String(pid)],
            timeout: 10
        )
        guard result.exitStatus == 0,
              let text = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// The command line a process is running under, as the system reports it.
    ///
    /// Split on spaces on purpose and nothing cleverer: what the caller does with it is ask whether
    /// a flag is present, and a flag with a space inside is not a flag. A path with a space would
    /// come back in pieces, which is why this is never used to *rebuild* a command, only to read
    /// the options off one.
    private func commandLine(of pid: Int32) async -> [String]? {
        let result = await commands.run(
            directory: NSHomeDirectory(),
            executable: processLister,
            arguments: ["-o", "args=", "-p", String(pid)],
            timeout: 10
        )
        guard result.exitStatus == 0,
              let text = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text.split(separator: " ").map(String.init)
    }

    /// The bare executable name of a command path, which is what a provider is named after.
    private static func executableName(of command: String) -> String {
        (command as NSString).lastPathComponent
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
