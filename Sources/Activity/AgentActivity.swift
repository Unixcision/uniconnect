import Foundation

/// Actividad de una IA (Claude, Codex, Gemini, Agy…) en una ventana de terminal.
///
/// Es el valor que el host publica al móvil (capacidad `activity.v1`) y el que la
/// barra lateral convierte en indicador. El host es la fuente de verdad: los
/// clientes no lo recalculan.
struct AgentActivity: Equatable, Hashable, Sendable {
    /// Qué está haciendo la IA en la ventana.
    enum State: String, Sendable, CaseIterable {
        /// La IA procesa (salida continua, hook `running` o marca de trabajo en el título).
        case working
        /// La IA espera una respuesta del usuario. Solo la producen los hooks y la pantalla.
        case waiting
        /// Hay una IA viva pero sin actividad reciente.
        case idle
        /// No hay IA identificable o no hay datos suficientes.
        case unknown

        /// Orden de agregación por espacio: `waiting` > `working` > `idle` > `unknown`.
        var aggregationRank: Int {
            switch self {
            case .waiting: return 3
            case .working: return 2
            case .idle: return 1
            case .unknown: return 0
            }
        }
    }

    /// Fuente que decidió el estado, de mayor a menor prioridad.
    enum Source: String, Sendable, CaseIterable {
        case hooks
        case title
        case screen
        case output
    }

    /// IA reconocida en la ventana.
    enum Agent: String, Sendable, CaseIterable {
        case claude
        case codex
        case gemini
        case agy

        /// Clave de `set_agent_lifecycle` / `set_status` (`claude_code`, `codex`, `gemini`, `antigravity`).
        init?(hookKey: String) {
            switch hookKey.lowercased() {
            case "claude_code", "claude": self = .claude
            case "codex": self = .codex
            case "gemini": self = .gemini
            case "antigravity", "agy": self = .agy
            default: return nil
            }
        }

        /// Tipo de conversación guardada en el registro de la ventana local.
        init?(restorableAgentKind: RestorableAgentKind?) {
            guard let restorableAgentKind else { return nil }
            switch restorableAgentKind {
            case .claude: self = .claude
            case .codex: self = .codex
            case .gemini: self = .gemini
            case .antigravity: self = .agy
            default: return nil
            }
        }
    }

    let state: State
    let source: Source
    let agent: Agent?
    /// Epoch en segundos del último cambio de `state`. `0` significa que nunca se evaluó.
    let since: TimeInterval

    init(state: State, source: Source, agent: Agent?, since: TimeInterval) {
        self.state = state
        self.source = source
        self.agent = agent
        self.since = since
    }

    /// Valor de reserva para ventanas que aún no se han evaluado.
    static let unevaluated = AgentActivity(state: .unknown, source: .output, agent: nil, since: 0)

    /// Estado agregado de un conjunto de ventanas: gana el de mayor rango.
    static func aggregateState<Activities: Sequence>(
        _ activities: Activities
    ) -> State where Activities.Element == AgentActivity {
        activities.map(\.state).max { $0.aggregationRank < $1.aggregationRank } ?? .unknown
    }

    /// Objeto `activity` de cada terminal en `mobile.workspace.list`.
    var mobilePayload: [String: Any] {
        [
            "state": state.rawValue,
            "source": source.rawValue,
            "agent": agent.map { $0.rawValue as Any } ?? NSNull(),
            "since": Int(since.rounded(.down)),
        ]
    }

    /// Objeto `activity` de cada espacio en `mobile.workspace.list`.
    static func mobileAggregatePayload(for state: State) -> [String: Any] {
        ["state": state.rawValue]
    }
}
