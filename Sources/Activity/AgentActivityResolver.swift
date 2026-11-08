import Foundation

/// Combina las pruebas de una ventana en un ``AgentActivity`` con las reglas del
/// contrato `activity.v1`:
///
/// 1. El agente sale del comando en primer plano o de los hooks; un shell es `unknown`.
/// 2. Hooks: `running` manda (`working`) mientras tenga menos de ``hooksMaxAge``;
///    `needsInput` (`waiting`) e `idle` mandan hasta el siguiente informe o hasta que la
///    IA muere (un shell en primer plano), y solo los vence una racha de salida de al
///    menos ``hooksOverrideOutputRun`` segundos, que es `working`.
/// 3. Si no: (a) pregunta de permiso visible → `waiting`, vence a todo; (b) título con
///    spinner braille → `working`; (c) salida en los últimos ``outputWorkingWindow``
///    segundos dentro de una racha de al menos ``minimumOutputRun`` → `working`; (d) sin
///    salida más de ``outputIdleWindow`` segundos con IA viva → `idle`; (e) entre ambas
///    ventanas, o con una ráfaga más corta que ``minimumOutputRun`` (un redibujado de
///    tmux), se conserva el `working`/`idle` anterior o, sin él, `idle`; (f) sin IA viva,
///    `unknown`.
/// 4. El título solo aporta evidencia positiva de trabajo, nunca de «parado».
/// 5. La pantalla se mira solo con la salida quieta al menos ``screenQuietWindow`` segundos.
/// 6. `since` es el epoch del último cambio de estado, no de cada sondeo.
struct AgentActivityResolver: Equatable, Sendable {
    /// Edad máxima (segundos) de un informe `running` (o `unknown`) de los hooks para
    /// tenerlo en cuenta. `idle` y `needsInput` no caducan.
    var hooksMaxAge: TimeInterval = 120
    /// Salida dentro de esta ventana (segundos) significa que la IA trabaja.
    var outputWorkingWindow: TimeInterval = 3
    /// Sin salida durante más de esto (segundos), con IA viva, la IA está inactiva.
    var outputIdleWindow: TimeInterval = 5
    /// Calma mínima (segundos) de la salida antes de mirar la pantalla.
    var screenQuietWindow: TimeInterval = 1
    /// Duración mínima (segundos) de la racha de salida para contar como trabajo.
    var minimumOutputRun: TimeInterval = 1
    /// Duración mínima (segundos) de la racha de salida que vence a un `idle` o
    /// `needsInput` de los hooks.
    var hooksOverrideOutputRun: TimeInterval = 3

    init(
        hooksMaxAge: TimeInterval = 120,
        outputWorkingWindow: TimeInterval = 3,
        outputIdleWindow: TimeInterval = 5,
        screenQuietWindow: TimeInterval = 1,
        minimumOutputRun: TimeInterval = 1,
        hooksOverrideOutputRun: TimeInterval = 3
    ) {
        self.hooksMaxAge = hooksMaxAge
        self.outputWorkingWindow = outputWorkingWindow
        self.outputIdleWindow = outputIdleWindow
        self.screenQuietWindow = screenQuietWindow
        self.minimumOutputRun = minimumOutputRun
        self.hooksOverrideOutputRun = hooksOverrideOutputRun
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
            // Un `idle`/`needsInput` no caduca: solo una racha larga demuestra que la IA
            // volvió a trabajar sin avisar; un redibujado o un cambio de título no basta.
            let outputOverridesHooks = hooksDecision != .working && isSustainedOutput(
                evidence.output, age: assessment.outputAge, minimumRun: hooksOverrideOutputRun
            )
            return outputOverridesHooks ? (.working, .output) : (hooksDecision, .hooks)
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
        if isSustainedOutput(evidence.output, age: age, minimumRun: minimumOutputRun) {
            return (.working, .output)
        }
        if age > outputIdleWindow {
            return (.idle, .output)
        }
        // Entre la ventana de trabajo y la de inactividad, o tras una ráfaga corta, se
        // conserva el estado anterior: un redibujado no despierta a una IA parada ni
        // corta a una que trabaja.
        if let previous, previous.state == .working || previous.state == .idle {
            return (previous.state, .output)
        }
        return (.idle, .output)
    }

    /// Salida reciente (dentro de ``outputWorkingWindow``) cuya racha dura al menos `minimumRun`.
    private func isSustainedOutput(
        _ output: AgentActivityEvidence.Output,
        age: TimeInterval?,
        minimumRun: TimeInterval
    ) -> Bool {
        guard let age, age <= outputWorkingWindow else { return false }
        return output.runDuration >= minimumRun
    }

    /// Lectura única de las pruebas para que las decisiones no repitan cálculos.
    private struct Assessment {
        /// Informe de hooks que aún cuenta: `running` y `unknown` hasta ``hooksMaxAge``;
        /// `idle` y `needsInput` mientras no haya un shell en primer plano.
        let liveHooks: AgentActivityEvidence.Hooks?
        let title: AgentActivityTitleSignal
        let agent: AgentActivity.Agent?
        let isAgentAlive: Bool
        let outputAge: TimeInterval?

        /// Estado dictado por los hooks vigentes; `nil` cuando no hay informe o es `unknown`.
        var hooksDecision: AgentActivity.State? {
            switch liveHooks?.lifecycle {
            case .running?: return .working
            case .needsInput?: return .waiting
            case .idle?: return .idle
            case .unknown?, nil: return nil
            }
        }

        init(evidence: AgentActivityEvidence, resolver: AgentActivityResolver, now: TimeInterval) {
            title = AgentActivityTitleSignal(
                title: evidence.title?.text,
                currentCommand: evidence.title?.currentCommand
            )
            let titleIsShell = title.isShell
            liveHooks = evidence.hooks.flatMap { hooks in
                switch hooks.lifecycle {
                case .idle, .needsInput:
                    // Duran hasta el siguiente informe; un shell en primer plano es que la IA murió.
                    return titleIsShell ? nil : hooks
                case .running, .unknown:
                    return now - hooks.reportedAt < resolver.hooksMaxAge ? hooks : nil
                }
            }
            if titleIsShell {
                agent = nil
                isAgentAlive = false
            } else {
                agent = liveHooks?.agent ?? title.agent ?? evidence.knownAgent
                isAgentAlive = liveHooks != nil || title.agent != nil || evidence.knownAgent != nil
                    || title.isAgentRuntime
            }
            outputAge = evidence.output.lastOutputAt.map { max(0, now - $0) }
        }
    }
}
