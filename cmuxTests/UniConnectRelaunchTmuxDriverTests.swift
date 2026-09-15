import CmuxProcess
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Lo que separa «la IA volvió» de «el panel sigue teniendo un shell».
///
/// El 15-09-2026 un relanzado real cerró una IA viva, la reabrió y aun así informó de que no había
/// salido y se había «quedado como estaba». La causa era mirar el proceso equivocado: tmux responde
/// el PID del **shell** del panel, que no cambia nunca porque la IA corre dentro de él.
///
/// El primer intento de arreglo tomaba «el último hijo», y eso tampoco acredita nada: con un
/// envoltorio la IA es nieta, y con una tarea de fondo hay varios candidatos. Aquí se comprueba lo
/// que se decidió en su lugar — recorrer el subárbol, exigir **exactamente una** coincidencia del
/// proveedor, y no adivinar nunca.
@Suite("Driver tmux del relanzado")
struct UniConnectRelaunchTmuxDriverTests {
    /// Un ejecutor de comandos que contesta por ejecutable y argumentos, y apunta lo que se le pidió.
    private final class FakeCommands: CommandRunning, @unchecked Sendable {
        // Solo lo tocan las llamadas secuenciales de una prueba; no hay concurrencia real aquí.
        private(set) var calls: [[String]] = []
        private let tmuxPanePID: String?
        private let table: String?
        private let started: String?

        init(tmuxPanePID: String?, table: String?, started: String? = "Mon Sep 15 11:47:02 2026") {
            self.tmuxPanePID = tmuxPanePID
            self.table = table
            self.started = started
        }

        func run(
            directory: String,
            executable: String,
            arguments: [String],
            timeout: TimeInterval?
        ) async -> CommandResult {
            calls.append([executable] + arguments)
            let answer: String?
            if executable == "tmux" {
                answer = tmuxPanePID
            } else if arguments.contains("-Ao") {
                answer = table
            } else {
                answer = started
            }
            return CommandResult(
                stdout: answer,
                stderr: nil,
                exitStatus: answer == nil ? 1 : 0,
                timedOut: false,
                executionError: nil
            )
        }
    }

    private func driver(_ commands: FakeCommands) -> UniConnectRelaunchTmuxDriver {
        UniConnectRelaunchTmuxDriver(commands: commands, executable: "tmux", processLister: "/bin/ps")
    }

    private func lookup(
        panePID: String? = "73694\n",
        table: String?,
        started: String? = "Mon Sep 15 11:47:02 2026"
    ) async -> UniConnectRelaunchAgentLookup {
        let commands = FakeCommands(tmuxPanePID: panePID, table: table, started: started)
        return await driver(commands).agent(socket: "uniconnect-local", pane: "%1", provider: "claude")
    }

    @Test("La IA hija del shell se encuentra, y no es el shell")
    func agentIsFoundUnderTheShell() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        52938 73694 claude
        """)

        // Si valiera el PID del panel (73694), ninguna prueba de «proceso nuevo» distinguiría un
        // relanzado que funcionó de uno que no hizo nada.
        #expect(found == .found(.init(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")))
    }

    @Test("La IA nieta, bajo un envoltorio, también se encuentra")
    func agentUnderAWrapperIsFound() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        80000 73694 claude-shim
        52938 80000 claude
        """)

        #expect(found == .found(.init(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")))
    }

    @Test("Un panel parado en su shell no tiene IA que cerrar")
    func paneSittingAtItsShellHasNoAgent() async {
        #expect(await lookup(table: "73694 73000 /bin/zsh") == .noAgent)
    }

    @Test("Una tarea de fondo no se confunde con la IA")
    func abackgroundJobIsNotTheAgent() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        52938 73694 claude
        60000 73694 rg
        """)

        #expect(found == .found(.init(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")))
    }

    @Test("Con dos IA del mismo proveedor no se adivina: es ambiguo")
    func twoAgentsOfTheSameProviderAreAmbiguous() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        52938 73694 claude
        52939 73694 claude
        """)

        // Cerrar una de las dos a ojo es cerrar trabajo de alguien.
        #expect(found == .ambiguous)
    }

    @Test("Si no se puede leer la tabla de procesos no se concluye que no haya IA")
    func anUnreadableProcessTableIsNotAnAbsentAgent() async {
        // La diferencia importa: «no hay IA» deja la ventana en paz, «no se pudo leer» detiene todo.
        #expect(await lookup(table: nil) != .noAgent)
        #expect(await lookup(table: nil) == .unreadable)
    }

    @Test("Si el shell del panel no aparece en la tabla, no se concluye que no haya IA")
    func ashellMissingFromTheTableIsNotAnAbsentAgent() async {
        // Tabla bien formada y no vacía, pero sin el PID que dijo tmux: lo que falla es la
        // correspondencia entre las dos lecturas, no el contenido del panel.
        let found = await lookup(table: """
        99999 1 /sbin/launchd
        88888 99999 zsh
        """)

        #expect(found != .noAgent)
        #expect(found == .unreadable)
    }

    @Test("Una fila ilegible invalida la tabla entera, no solo esa fila")
    func anunparsableRowInvalidatesTheWholeTable() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        ???? basura
        52938 73694 claude
        """)

        // Descartarla en silencio convertiría una lectura incompleta en una decisión de cerrar.
        #expect(found == .unreadable)
    }

    @Test("Una tabla vacía con salida correcta no es un sistema sin procesos")
    func anemptyTableIsNotASystemWithoutProcesses() async {
        #expect(await lookup(table: "") == .unreadable)
    }

    @Test("Si tmux no contesta, tampoco")
    func anUnreadablePaneIsNotAnAbsentAgent() async {
        #expect(await lookup(panePID: nil, table: "73694 73000 /bin/zsh") == .unreadable)
    }

    @Test("Sin hora de arranque no se acredita el proceso")
    func aProcessWithoutAStartTimeIsNotAccredited() async {
        let found = await lookup(table: """
        73694 73000 /bin/zsh
        52938 73694 claude
        """, started: nil)

        #expect(found == .unreadable)
    }

    @Test("Un PID reciclado no pasa por el mismo proceso")
    func arecycledIdentifierIsNotTheSameProcess() {
        let antes = UniConnectRelaunchAgentProcess(pid: 52938, startedAt: "Mon Sep 15 11:00:00 2026")
        let despues = UniConnectRelaunchAgentProcess(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")

        // Mismo número, proceso distinto: comparar solo el PID daría «no ha cambiado nada».
        #expect(antes.pid == despues.pid)
        #expect(!antes.isSameProcess(as: despues))
    }

    @Test("El mismo proceso se reconoce como el mismo")
    func thesameProcessKeepsItsGeneration() {
        let uno = UniConnectRelaunchAgentProcess(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")
        let otro = UniConnectRelaunchAgentProcess(pid: 52938, startedAt: "Mon Sep 15 11:47:02 2026")

        #expect(uno.isSameProcess(as: otro))
    }
}
