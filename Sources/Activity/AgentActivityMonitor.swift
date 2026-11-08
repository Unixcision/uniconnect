import Foundation

/// Servicio que decide la ``AgentActivity`` de cada ventana a partir de sus pruebas.
///
/// Corre fuera del hilo principal: lanza la sonda de tmux (una por socket), completa
/// las pruebas con el título, el comando y la salida del panel, pide el veredicto de
/// pantalla solo a las ventanas en calma y aplica el ``AgentActivityResolver``. Conserva
/// la decisión anterior de cada ventana para calcular `since` y la histéresis.
///
/// En las ventanas con tmux local la salida sale de `#{window_activity}`, no de la PTY:
/// esa PTY es un cliente `tmux attach` y ve los redibujados que cualquier `set-option` o
/// `set-hook` provoca en todos los clientes del servidor, sin que el panel escriba nada.
/// Como tmux solo da la última actividad (en segundos enteros), la racha se reconstruye
/// entre evaluaciones: sigue mientras cada muestra encuentre actividad fresca.
actor AgentActivityMonitor {
    /// Antigüedad máxima (segundos) de `#{window_activity}` en una muestra para que la
    /// racha siga: el hueco de la racha de la PTY más el segundo de resolución de tmux.
    static let windowActivityRunFreshness: TimeInterval = AgentOutputActivityCell.runBreakGap + 1

    private let probe: TmuxPaneActivityProbe
    private let resolver: AgentActivityResolver
    private var previousByPanelID: [UUID: AgentActivity] = [:]
    /// Salida muestreada de tmux por ventana en la evaluación anterior.
    private var windowActivityOutputByPanelID: [UUID: AgentActivityEvidence.Output] = [:]
    /// Epoch de la evaluación anterior; `nil` antes de la primera.
    private var previousEvaluationAt: TimeInterval?

    /// - Parameters:
    ///   - probe: Sonda de tmux; los tests inyectan un ejecutor falso a través de ella.
    ///   - resolver: Reglas de combinación de fuentes.
    init(probe: TmuxPaneActivityProbe = TmuxPaneActivityProbe(), resolver: AgentActivityResolver = AgentActivityResolver()) {
        self.probe = probe
        self.resolver = resolver
    }

    /// Evalúa todas las ventanas y devuelve su actividad agrupada por espacio.
    ///
    /// - Parameters:
    ///   - inputs: Pruebas recogidas en el hilo principal.
    ///   - now: Epoch en segundos de la evaluación.
    ///   - screenShowsPermissionPrompt: Veredicto de pantalla para las ventanas que lo necesiten.
    func evaluate(
        inputs: [AgentActivityTerminalInput],
        now: TimeInterval,
        screenShowsPermissionPrompt: @MainActor @Sendable (UUID) -> Bool
    ) async -> [UUID: [UUID: AgentActivity]] {
        let rowsBySocket = await probeRows(socketNames: Set(inputs.compactMap { $0.tmux?.socketName }))
        var next: [UUID: AgentActivity] = [:]
        var nextWindowActivityOutputs: [UUID: AgentActivityEvidence.Output] = [:]
        var result: [UUID: [UUID: AgentActivity]] = [:]
        for input in inputs {
            var evidence = input.evidence
            if let tmux = input.tmux, let row = rowsBySocket[tmux.socketName]?[tmux.sessionName] {
                evidence.title = AgentActivityEvidence.Title(text: row.title, currentCommand: row.currentCommand)
                if let windowActivity = row.windowActivity {
                    let output = windowActivityOutput(panelID: input.panelID, windowActivity: windowActivity)
                    evidence.output = output
                    nextWindowActivityOutputs[input.panelID] = output
                }
            }
            if resolver.needsScreenCheck(evidence: evidence, now: now) {
                evidence.screenShowsPermissionPrompt = await screenShowsPermissionPrompt(input.panelID)
            }
            let activity = resolver.resolve(
                evidence: evidence,
                previous: previousByPanelID[input.panelID],
                now: now
            )
            next[input.panelID] = activity
            result[input.workspaceID, default: [:]][input.panelID] = activity
        }
        previousByPanelID = next
        windowActivityOutputByPanelID = nextWindowActivityOutputs
        previousEvaluationAt = now
        return result
    }

    /// Salida de una ventana con tmux a partir de su `#{window_activity}`: la racha anterior
    /// continúa si en la muestra previa ya había actividad fresca; si no, empieza en esta.
    private func windowActivityOutput(panelID: UUID, windowActivity: TimeInterval) -> AgentActivityEvidence.Output {
        guard let previous = windowActivityOutputByPanelID[panelID],
              let previousActivity = previous.lastOutputAt,
              let previousRunStart = previous.runStartedAt,
              let previousEvaluationAt else {
            return AgentActivityEvidence.Output(lastOutputAt: windowActivity, runStartedAt: windowActivity)
        }
        if windowActivity <= previousActivity {
            return previous
        }
        let wasFresh = previousEvaluationAt - previousActivity <= Self.windowActivityRunFreshness
        return AgentActivityEvidence.Output(
            lastOutputAt: windowActivity,
            runStartedAt: wasFresh ? previousRunStart : windowActivity
        )
    }

    private func probeRows(socketNames: Set<String>) async -> [String: [String: TmuxPaneActivityRow]] {
        guard !socketNames.isEmpty else { return [:] }
        let probe = self.probe
        return await withTaskGroup(of: (String, [String: TmuxPaneActivityRow]).self) { group in
            for socketName in socketNames {
                group.addTask {
                    (socketName, await probe.rowsBySession(socketName: socketName))
                }
            }
            var rows: [String: [String: TmuxPaneActivityRow]] = [:]
            for await (socketName, sessions) in group {
                rows[socketName] = sessions
            }
            return rows
        }
    }
}
