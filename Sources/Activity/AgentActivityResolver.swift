import Foundation

/// Combina las pruebas de una ventana en un ``AgentActivity`` siguiendo la prioridad
/// hooks > título > pantalla > salida.
///
/// Gana la fuente más alta con dato fresco. Si título, pantalla o salida dicen «no
/// trabaja» pero hay salida continua, manda la salida (`working`). `waiting` solo
/// sale de los hooks o de la pantalla, nunca de la salida.
struct AgentActivityResolver: Equatable, Sendable {
    /// Edad máxima (segundos) de un informe de hooks para tenerlo en cuenta.
    var hooksMaxAge: TimeInterval = 120
    /// Salida dentro de esta ventana (segundos) significa que la IA trabaja.
    var outputWorkingWindow: TimeInterval = 3
    /// Sin salida durante más de esto (segundos), con IA viva, la IA está inactiva.
    var outputIdleWindow: TimeInterval = 5

    init(hooksMaxAge: TimeInterval = 120, outputWorkingWindow: TimeInterval = 3, outputIdleWindow: TimeInterval = 5) {
        self.hooksMaxAge = hooksMaxAge
        self.outputWorkingWindow = outputWorkingWindow
        self.outputIdleWindow = outputIdleWindow
    }

    /// Solo merece leer la pantalla cuando ninguna fuente superior ha decidido, la
    /// salida está en calma y hay una IA viva que podría estar preguntando.
    func needsScreenCheck(evidence: AgentActivityEvidence, now: TimeInterval) -> Bool {
        let assessment = Assessment(evidence: evidence, resolver: self, now: now)
        if let hooks = assessment.freshHooks, hooks.lifecycle != .unknown {
            return false
        }
        if assessment.title.isShell || assessment.title.state == .working || assessment.hasRecentOutput {
            return false
        }
        return assessment.isAgentAlive
    }

    func resolve(evidence: AgentActivityEvidence, previous: AgentActivity?, now: TimeInterval) -> AgentActivity {
        let assessment = Assessment(evidence: evidence, resolver: self, now: now)
        let decision = decide(assessment, previous: previous, screenText: evidence.screenText)
        let agent = decision.state == .unknown ? nil : assessment.agent
        let since = previous.flatMap { $0.state == decision.state ? $0.since : nil } ?? now
        return AgentActivity(state: decision.state, source: decision.source, agent: agent, since: since)
    }

    private func decide(
        _ assessment: Assessment,
        previous: AgentActivity?,
        screenText: String?
    ) -> (state: AgentActivity.State, source: AgentActivity.Source) {
        if let hooks = assessment.freshHooks {
            switch hooks.lifecycle {
            case .running: return (.working, .hooks)
            case .needsInput: return (.waiting, .hooks)
            case .idle: return (.idle, .hooks)
            case .unknown: break
            }
        }
        if assessment.title.isShell {
            return (.unknown, .title)
        }
        if assessment.title.state == .working {
            return (.working, .title)
        }
        if assessment.hasRecentOutput, assessment.isAgentAlive {
            return (.working, .output)
        }
        if assessment.isAgentAlive, AgentActivityScreenSignal(visibleText: screenText).isWaitingForUser {
            return (.waiting, .screen)
        }
        if assessment.title.state == .idle {
            return (.idle, .title)
        }
        guard assessment.isAgentAlive else {
            return (.unknown, .output)
        }
        // Histéresis entre la ventana de trabajo y la de inactividad: se conserva `working`.
        if let age = assessment.outputAge, age <= outputIdleWindow, previous?.state == .working {
            return (.working, .output)
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
        let hasRecentOutput: Bool

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
            }
            outputAge = evidence.output.lastOutputAt.map { max(0, now - $0) }
            hasRecentOutput = outputAge.map { $0 <= resolver.outputWorkingWindow } ?? false
        }
    }
}
