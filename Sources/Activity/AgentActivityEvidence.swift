import Foundation

/// Pruebas recogidas para una ventana antes de decidir su ``AgentActivity``.
///
/// Las rellena ``AgentActivityWorkspaceBridge`` en el hilo principal y las completa
/// ``AgentActivityMonitor`` (sonda de tmux, lectura de pantalla). El
/// ``AgentActivityResolver`` solo las lee.
struct AgentActivityEvidence: Equatable, Sendable {
    /// Último informe de los hooks del agente (`set_agent_lifecycle` o `set_status`).
    struct Hooks: Equatable, Sendable {
        let lifecycle: AgentHibernationLifecycleState
        let agent: AgentActivity.Agent?
        /// Epoch en segundos en que se recibió el informe.
        let reportedAt: TimeInterval

        init(lifecycle: AgentHibernationLifecycleState, agent: AgentActivity.Agent?, reportedAt: TimeInterval) {
            self.lifecycle = lifecycle
            self.agent = agent
            self.reportedAt = reportedAt
        }

        /// Traduce el texto de un `set_status` (por ejemplo «Idle», «Running», «Needs input»)
        /// al ciclo de vida equivalente. Devuelve `.unknown` cuando el texto no dice nada.
        static func lifecycle(fromStatusValue value: String) -> AgentHibernationLifecycleState {
            let lowered = value.lowercased()
            let needsInputMarkers = ["input", "wait", "permission", "approv", "question", "confirm"]
            if needsInputMarkers.contains(where: { lowered.contains($0) }) {
                return .needsInput
            }
            let runningMarkers = ["running", "working", "thinking", "busy", "processing"]
            if runningMarkers.contains(where: { lowered.contains($0) }) {
                return .running
            }
            let idleMarkers = ["idle", "done", "finished", "complete"]
            if idleMarkers.contains(where: { lowered.contains($0) }) {
                return .idle
            }
            return .unknown
        }
    }

    /// Título de la ventana y comando en primer plano.
    struct Title: Equatable, Sendable {
        /// Título OSC de la superficie o `pane_title` de tmux.
        let text: String?
        /// `pane_current_command` de tmux o nombre del proceso en primer plano de la PTY.
        let currentCommand: String?

        init(text: String?, currentCommand: String?) {
            self.text = text
            self.currentCommand = currentCommand
        }
    }

    /// Actividad real de salida de la PTY (sin eco de teclado ni redibujados por tamaño).
    struct Output: Equatable, Sendable {
        /// Epoch en segundos de la última salida contada; `nil` si nunca hubo.
        let lastOutputAt: TimeInterval?

        init(lastOutputAt: TimeInterval?) {
            self.lastOutputAt = lastOutputAt
        }
    }

    var hooks: Hooks?
    var title: Title?
    /// IA que el registro de la ventana local dice que está en marcha (conversación activa).
    var knownAgent: AgentActivity.Agent?
    var output: Output
    /// Texto visible de la superficie; `nil` mientras no se haya leído la pantalla.
    var screenText: String?

    init(
        hooks: Hooks? = nil,
        title: Title? = nil,
        knownAgent: AgentActivity.Agent? = nil,
        output: Output = Output(lastOutputAt: nil),
        screenText: String? = nil
    ) {
        self.hooks = hooks
        self.title = title
        self.knownAgent = knownAgent
        self.output = output
        self.screenText = screenText
    }
}
