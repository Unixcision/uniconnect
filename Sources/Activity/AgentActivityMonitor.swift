import Foundation

/// Servicio que decide la ``AgentActivity`` de cada ventana a partir de sus pruebas.
///
/// Corre fuera del hilo principal: lanza la sonda de tmux (una por socket), completa
/// las pruebas con el título y el comando del panel, pide el veredicto de pantalla solo
/// a las ventanas en calma y aplica el ``AgentActivityResolver``. Conserva la decisión
/// anterior de cada ventana para calcular `since` y la histéresis.
actor AgentActivityMonitor {
    private let probe: TmuxPaneActivityProbe
    private let resolver: AgentActivityResolver
    private var previousByPanelID: [UUID: AgentActivity] = [:]

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
        var result: [UUID: [UUID: AgentActivity]] = [:]
        for input in inputs {
            var evidence = input.evidence
            if let tmux = input.tmux, let row = rowsBySocket[tmux.socketName]?[tmux.sessionName] {
                evidence.title = AgentActivityEvidence.Title(text: row.title, currentCommand: row.currentCommand)
                if evidence.output.lastOutputAt == nil {
                    evidence.output = AgentActivityEvidence.Output(lastOutputAt: row.windowActivity)
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
        return result
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
