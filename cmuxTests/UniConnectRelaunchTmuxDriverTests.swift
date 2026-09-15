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
/// El 15-09-2026 un relanzado real cerró una IA viva, la reabrió y aun asi informó de que no había
/// salido y se había «quedado como estaba». La causa era comparar el proceso equivocado: tmux
/// responde el PID del **shell** del panel, que no cambia nunca porque la IA corre dentro de él.
@Suite("Driver tmux del relanzado")
struct UniConnectRelaunchTmuxDriverTests {
    /// Un ejecutor de comandos que contesta lo que se le diga, y apunta lo que le preguntaron.
    private final class FakeCommands: CommandRunning, @unchecked Sendable {
        // Solo lo tocan las llamadas secuenciales de una prueba; no hay concurrencia real aquí.
        private(set) var calls: [(executable: String, arguments: [String])] = []
        private let answers: [String: (String?, Int32)]

        init(answers: [String: (String?, Int32)]) {
            self.answers = answers
        }

        func run(
            directory: String,
            executable: String,
            arguments: [String],
            timeout: TimeInterval?
        ) async -> CommandResult {
            calls.append((executable, arguments))
            let (stdout, status) = answers[executable] ?? (nil, 1)
            return CommandResult(
                stdout: stdout,
                stderr: nil,
                exitStatus: status,
                timedOut: false,
                executionError: nil
            )
        }
    }

    @Test("El PID del agente es el hijo del shell, no el shell")
    func agentPIDIsTheShellsChild() async {
        let commands = FakeCommands(answers: [
            "tmux": ("73694\n", 0),      // el shell del panel
            "/usr/bin/pgrep": ("52938\n", 0),  // la IA dentro de él
        ])
        let driver = UniConnectRelaunchTmuxDriver(commands: commands, executable: "tmux")

        let shell = await driver.panePID(socket: "uniconnect-local", pane: "%1")
        let agent = await driver.agentPID(socket: "uniconnect-local", pane: "%1")

        #expect(shell == 73694)
        #expect(agent == 52938)
        // Si fueran iguales, ninguna prueba de «proceso nuevo» podría distinguir un relanzado
        // que funcionó de uno que no hizo nada.
        #expect(agent != shell)
        #expect(commands.calls.contains { $0.executable == "/usr/bin/pgrep" && $0.arguments == ["-P", "73694"] })
    }

    @Test("Un panel parado en su shell no tiene agente que cerrar")
    func paneSittingAtItsShellHasNoAgent() async {
        let commands = FakeCommands(answers: [
            "tmux": ("73694\n", 0),
            "/usr/bin/pgrep": ("", 1),  // pgrep sin coincidencias sale con 1
        ])
        let driver = UniConnectRelaunchTmuxDriver(commands: commands, executable: "tmux")

        #expect(await driver.agentPID(socket: "uniconnect-local", pane: "%1") == nil)
    }

    @Test("Con varios hijos se toma el más reciente")
    func theNewestChildWins() async {
        let commands = FakeCommands(answers: [
            "tmux": ("73694\n", 0),
            "/usr/bin/pgrep": ("41000\n52938\n", 0),
        ])
        let driver = UniConnectRelaunchTmuxDriver(commands: commands, executable: "tmux")

        #expect(await driver.agentPID(socket: "uniconnect-local", pane: "%1") == 52938)
    }
}
