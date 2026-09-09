import Foundation

/// Combina las pruebas de una ventana en un ``AgentActivity`` con las reglas del
/// contrato `activity.v1`:
///
/// 1. El agente sale del comando en primer plano o de los hooks; un shell es `unknown`.
/// 2. Un informe de hooks de menos de ``hooksMaxAge`` manda (`waiting` | `working` | `idle`).
/// 3. Si no: (a) pregunta de permiso visible → `waiting`, vence a todo; (b) título con
///    spinner braille → `working`; (c) salida de la PTY en los últimos
///    ``outputWorkingWindow`` segundos → `working`; (d) sin salida más de
///    ``outputIdleWindow`` segundos con IA viva → `idle`; (e) si no, `unknown`.
/// 4. El título solo aporta evidencia positiva de trabajo, nunca de «parado».
/// 5. La pantalla se mira solo con la salida quieta al menos ``screenQuietWindow`` segundos.
/// 6. `since` es el epoch del último cambio de estado, no de cada sondeo.
struct AgentActivityResolver: Equatable, Sendable {
    /// Edad máxima (segundos) de un informe de hooks para tenerlo en cuenta.
    var hooksMaxAge: TimeInterval = 120
    /// Salida dentro de esta ventana (segundos) significa que la IA trabaja.
    var outputWorkingWindow: TimeInterval = 3
    /// Sin salida durante más de esto (segundos), con IA viva, la IA está inactiva.
    var outputIdleWindow: TimeInterval = 5
    /// Calma mínima (segundos) de la salida antes de mirar la pantalla.
    var screenQuietWindow: TimeInterval = 1

    init(
        hooksMaxAge: TimeInterval = 120,
        outputWorkingWindow: TimeInterval = 3,
        outputIdleWindow: TimeInterval = 5,
        screenQuietWindow: TimeInterval = 1
    ) {
        self.hooksMaxAge = hooksMaxAge
        self.outputWorkingWindow = outputWorkingWindow
        self.outputIdleWindow = outputIdleWindow
        self.screenQuietWindow = screenQuietWindow
    }

    /// Solo merece mirar la pantalla cuando los hooks no han decidido, la ventana no es un
    /// shell, la salida lleva quieta al menos ``screenQuietWindow`` y hay una IA viva o el
    /// proceso real no es visible (ssh, tmux).
    func needsScreenCheck(evidence: AgentActivityEvidence, now: TimeInterval) -> Bool {
        let assessment = Assessment(evidence: evidence, resolver: self, now: now)
        if assessment.hooksDecision != nil || assessment.title.isShell {
            return false
        }
        if let age = assessment.outputAge, age < screenQuietWindow {
            return false
        }
        return assessment.isAgentAlive || assessment.title.hidesForegroundProcess
    }

    func resolve(evidence: AgentActivityEvidence, previous: AgentActivity?, now: TimeInterval) -> AgentActivity {
        let assessment = Assessment(evidence: evidence, resolver: self, now: now)
        let decision = decide(assessment, evidence: evidence, previous: previous)
        let agent = decision.state == .unknown ? nil : assessment.agent
        let since = previous.flatMap { $0.state == decision.state ? $0.since : nil } ?? now
        return AgentActivity(state: decision.state, source: decision.source, agent: agent, since: since)
    }

    private func decide(
        _ assessment: Assessment,
        evidence: AgentActivityEvidence,
        previous: AgentActivity?
    ) -> (state: AgentActivity.State, source: AgentActivity.Source) {
        if let hooksDecision = assessment.hooksDecision {
            return (hooksDecision, .hooks)
        }
        if assessment.title.isShell {
            return (.unknown, .title)
        }
        if evidence.screenShowsPermissionPrompt == true {
            return (.waiting, .screen)
        }
        if assessment.title.state == .working {
            return (.working, .title)
        }
        guard assessment.isAgentAlive else {
            return (.unknown, .output)
        }
        guard let age = assessment.outputAge else {
            return (.idle, .output)
        }
        if age <= outputWorkingWindow {
            return (.working, .output)
        }
        if age > outputIdleWindow {
            return (.idle, .output)
        }
        // Entre la ventana de trabajo y la de inactividad se conserva el estado anterior.
        if let previous, previous.state == .working || previous.state == .idle {
            return (previous.state, .output)
        }
        return (.idle, .output)
    }

    /// Lectura única de las pruebas para que las decisiones no repitan cálculos.
    private struct Assessment {
        let freshHooks: AgentActivityEvidence.Hooks?
        let title: AgentActivityTitleSignal
        let agent: AgentActivity.Agent?
        let isAgentAlive: Bool
        let outputAge: TimeInterval?

        /// Estado dictado por hooks frescos; `nil` cuando no hay informe o es `unknown`.
        var hooksDecision: AgentActivity.State? {
            switch freshHooks?.lifecycle {
            case .running?: return .working
            case .needsInput?: return .waiting
            case .idle?: return .idle
            case .unknown?, nil: return nil
            }
        }

        init(evidence: AgentActivityEvidence, resolver: AgentActivityResolver, now: TimeInterval) {
            freshHooks = evidence.hooks.flatMap { hooks in
                now - hooks.reportedAt < resolver.hooksMaxAge ? hooks : nil
            }
            title = AgentActivityTitleSignal(
                title: evidence.title?.text,
                currentCommand: evidence.title?.currentCommand
            )
            if title.isShell {
                agent = nil
                isAgentAlive = false
            } else {
                agent = freshHooks?.agent ?? title.agent ?? evidence.knownAgent
                isAgentAlive = freshHooks != nil || title.agent != nil || evidence.knownAgent != nil
                    || title.isAgentRuntime
            }
            outputAge = evidence.output.lastOutputAt.map { max(0, now - $0) }
        }
    }
}
