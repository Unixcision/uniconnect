import CmuxProcess
import Foundation

/// Sonda única por socket de tmux: un `tmux -L <socket> list-panes -a` fuera del hilo
/// principal cuyo resultado se reparte por sesión (`uc-<hex>`).
struct TmuxPaneActivityProbe: Sendable {
    private let commands: any CommandRunning
    private let timeout: TimeInterval
    private let workingDirectory: String

    /// - Parameters:
    ///   - commands: Ejecutor de procesos; los tests inyectan uno falso.
    ///   - timeout: Segundos antes de abandonar la sonda (tmux colgado no debe bloquear el ciclo).
    ///   - workingDirectory: Directorio de trabajo del proceso; irrelevante para tmux.
    init(
        commands: any CommandRunning = CommandRunner(),
        timeout: TimeInterval = 1.5,
        workingDirectory: String = NSHomeDirectory()
    ) {
        self.commands = commands
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }

    /// Filas por sesión del socket indicado; vacío si tmux no responde o no hay servidor.
    func rowsBySession(socketName: String) async -> [String: TmuxPaneActivityRow] {
        guard let output = await commands.runStandardOutput(
            directory: workingDirectory,
            executable: "tmux",
            arguments: ["-L", socketName, "list-panes", "-a", "-F", TmuxPaneActivityRow.formatArgument],
            timeout: timeout
        ) else {
            return [:]
        }
        return TmuxPaneActivityRow.latestBySession(TmuxPaneActivityRow.parse(output))
    }
}
