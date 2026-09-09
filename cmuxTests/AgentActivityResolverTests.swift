import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Lógica pura de la actividad de IA (`activity.v1`): título, pantalla, prioridad de
/// fuentes, agregación por espacio, sonda de tmux y filtro de eco.
@Suite("Actividad de IA")
struct AgentActivityResolverTests {
    private let now: TimeInterval = 1_800_000_000
    private let resolver = AgentActivityResolver()

    private func evidence(
        hooks: AgentActivityEvidence.Hooks? = nil,
        title: String? = nil,
        command: String? = nil,
        knownAgent: AgentActivity.Agent? = nil,
        outputAge: TimeInterval? = nil,
        screen: Bool? = nil
    ) -> AgentActivityEvidence {
        AgentActivityEvidence(
            hooks: hooks,
            title: AgentActivityEvidence.Title(text: title, currentCommand: command),
            knownAgent: knownAgent,
            output: AgentActivityEvidence.Output(lastOutputAt: outputAge.map { now - $0 }),
            screenShowsPermissionPrompt: screen
        )
    }

    private func resolve(_ evidence: AgentActivityEvidence, previous: AgentActivity? = nil) -> AgentActivity {
        resolver.resolve(evidence: evidence, previous: previous, now: now)
    }

    // MARK: Regla 1 y 4: agente por comando, título solo como evidencia positiva

    @Test("El ✳ de Claude identifica al agente pero no dice nada del estado")
    func claudeMarkerIsNotStateEvidence() {
        let signal = AgentActivityTitleSignal(title: "✳ Arreglar el build", currentCommand: "claude")
        #expect(signal.agent == .claude)
        #expect(signal.state == nil)
        #expect(!signal.isShell)
        let viaNode = AgentActivityTitleSignal(title: "✳ Arreglar el build", currentCommand: "node")
        #expect(viaNode.agent == .claude)
        #expect(viaNode.state == nil)
        let dotted = AgentActivityTitleSignal(title: "· Arreglar el build", currentCommand: "claude")
        #expect(dotted.state == nil)
    }

    @Test("Codex trabaja con spinner braille; sin él el título no dice nada")
    func codexBrailleSpinner() {
        let working = AgentActivityTitleSignal(title: "⠋ codex", currentCommand: "codex")
        #expect(working.agent == .codex)
        #expect(working.state == .working)
        let stopped = AgentActivityTitleSignal(title: "codex", currentCommand: "codex")
        #expect(stopped.agent == .codex)
        #expect(stopped.state == nil)
        let inferred = AgentActivityTitleSignal(title: "⣾ resumen", currentCommand: "node")
        #expect(inferred.agent == .codex)
        #expect(inferred.state == .working)
    }

    @Test("Un shell en primer plano anula el título", arguments: ["zsh", "-zsh", "/bin/bash", "fish"])
    func shellCommand(command: String) {
        let signal = AgentActivityTitleSignal(title: "⠋ algo", currentCommand: command)
        #expect(signal.isShell)
        #expect(signal.agent == nil)
        #expect(signal.state == nil)
    }

    @Test("Gemini y Agy dan agente sin estado; ssh y tmux ocultan el proceso real")
    func agentsAndOpaqueCommands() {
        let gemini = AgentActivityTitleSignal(title: "Gemini CLI", currentCommand: "gemini")
        #expect(gemini.agent == .gemini)
        #expect(gemini.state == nil)
        let agy = AgentActivityTitleSignal(title: "cualquier cosa", currentCommand: "agy")
        #expect(agy.agent == .agy)
        let ssh = AgentActivityTitleSignal(title: "user@host: ~", currentCommand: "ssh")
        #expect(ssh.agent == nil)
        #expect(!ssh.isShell)
        #expect(ssh.hidesForegroundProcess)
        let vim = AgentActivityTitleSignal(title: "main.swift", currentCommand: "vim")
        #expect(!vim.hidesForegroundProcess)
    }

    // MARK: Regla 2: los hooks frescos mandan

    @Test("Los hooks frescos vencen al spinner del título")
    func freshHooksWin() {
        let hooks = AgentActivityEvidence.Hooks(lifecycle: .idle, agent: .codex, reportedAt: now - 10)
        let activity = resolve(evidence(hooks: hooks, title: "⠋ codex", command: "codex", outputAge: 1))
        #expect(activity.state == .idle)
        #expect(activity.source == .hooks)
        #expect(activity.agent == .codex)
        #expect(activity.since == now)
    }

    @Test("running y needsInput de los hooks son working y waiting")
    func hooksStates() {
        let running = AgentActivityEvidence.Hooks(lifecycle: .running, agent: .claude, reportedAt: now - 1)
        #expect(resolve(evidence(hooks: running, command: "claude")).state == .working)
        let needsInput = AgentActivityEvidence.Hooks(lifecycle: .needsInput, agent: .claude, reportedAt: now - 1)
        let waiting = resolve(evidence(hooks: needsInput, command: "claude", outputAge: 0))
        #expect(waiting.state == .waiting)
        #expect(waiting.source == .hooks)
    }

    @Test("Los hooks de más de 120 s se ignoran")
    func staleHooksIgnored() {
        let hooks = AgentActivityEvidence.Hooks(lifecycle: .needsInput, agent: .codex, reportedAt: now - 200)
        let activity = resolve(evidence(hooks: hooks, title: "⠋ codex", command: "codex"))
        #expect(activity.state == .working)
        #expect(activity.source == .title)
    }

    // MARK: Regla 3a: la pregunta de permiso visible vence a todo lo que no sea hooks

    @Test("Pregunta de permiso visible es waiting aunque haya spinner o salida")
    func screenBeatsTitleAndOutput() {
        let activity = resolve(evidence(title: "⠋ codex", command: "codex", outputAge: 2, screen: true))
        #expect(activity.state == .waiting)
        #expect(activity.source == .screen)
        #expect(activity.agent == .codex)
        let remote = resolve(evidence(title: "user@host", command: "ssh", screen: true))
        #expect(remote.state == .waiting)
        #expect(remote.agent == nil)
    }

    @Test("La pantalla solo se mira con salida quieta ≥ 1 s y sin hooks decisivos")
    func needsScreenCheck() {
        #expect(!resolver.needsScreenCheck(evidence: evidence(command: "zsh", outputAge: 10), now: now))
        #expect(!resolver.needsScreenCheck(evidence: evidence(command: "claude", outputAge: 0.5), now: now))
        #expect(resolver.needsScreenCheck(evidence: evidence(command: "claude", outputAge: 1), now: now))
        #expect(resolver.needsScreenCheck(evidence: evidence(title: "⠋ codex", command: "codex", outputAge: 4), now: now))
        let hooks = AgentActivityEvidence.Hooks(lifecycle: .running, agent: .claude, reportedAt: now)
        #expect(!resolver.needsScreenCheck(evidence: evidence(hooks: hooks, command: "claude", outputAge: 10), now: now))
        #expect(resolver.needsScreenCheck(evidence: evidence(command: "ssh", outputAge: 10), now: now))
        #expect(resolver.needsScreenCheck(evidence: evidence(command: "python3", knownAgent: .agy), now: now))
        #expect(!resolver.needsScreenCheck(evidence: evidence(command: "vim", outputAge: 10), now: now))
    }

    @Test("Patrones de permiso de Claude, Gemini y Codex; solo cuentan las últimas líneas")
    func screenPatterns() {
        let claude = "\u{1B}[1mEdit file\u{1B}[0m\nDo you want to make this edit?\n❯ 1. Yes\n  2. No\nEsc to cancel"
        #expect(AgentActivityScreenSignal(visibleText: claude).isWaitingForUser)
        #expect(AgentActivityScreenSignal(visibleText: "Allow execution of: ls -la?\n● Allow once").isWaitingForUser)
        #expect(AgentActivityScreenSignal(visibleText: "Allow command? [y/n]").isWaitingForUser)
        #expect(!AgentActivityScreenSignal(visibleText: "✻ Prestidigitating… still thinking").isWaitingForUser)
        #expect(!AgentActivityScreenSignal(visibleText: "git log: approve the release").isWaitingForUser)
        #expect(!AgentActivityScreenSignal(visibleText: nil).isWaitingForUser)
        let scrolledAway = "Do you want to proceed?\n" + Array(repeating: "línea", count: 20).joined(separator: "\n")
        #expect(!AgentActivityScreenSignal(visibleText: scrolledAway).isWaitingForUser)
    }

    // MARK: Reglas 3b–3e: spinner, salida, inactividad, desconocido

    @Test("Spinner braille sin hooks ni pregunta es working por título")
    func brailleWithoutHooks() {
        let activity = resolve(evidence(title: "⠙ codex", command: "codex", outputAge: 30, screen: false))
        #expect(activity.state == .working)
        #expect(activity.source == .title)
    }

    @Test("Claude con ✳: salida reciente es working y calma larga es idle")
    func claudeOutputWindows() {
        let working = resolve(evidence(title: "✳ tema", command: "claude", outputAge: 1))
        #expect(working.state == .working)
        #expect(working.source == .output)
        #expect(working.agent == .claude)
        let idle = resolve(evidence(title: "✳ tema", command: "claude", outputAge: 6, screen: false))
        #expect(idle.state == .idle)
        #expect(idle.source == .output)
        let never = resolve(evidence(title: "✳ tema", command: "claude", screen: false))
        #expect(never.state == .idle)
    }

    @Test("Entre 3 y 5 s sin salida se conserva el estado anterior")
    func hysteresis() {
        let working = AgentActivity(state: .working, source: .output, agent: .claude, since: now - 20)
        let kept = resolve(evidence(command: "claude", outputAge: 4), previous: working)
        #expect(kept.state == .working)
        #expect(kept.since == now - 20)
        let idle = AgentActivity(state: .idle, source: .output, agent: .claude, since: now - 20)
        #expect(resolve(evidence(command: "claude", outputAge: 4), previous: idle).state == .idle)
        #expect(resolve(evidence(command: "claude", outputAge: 4)).state == .idle)
    }

    @Test("Un shell con salida sigue siendo unknown y sin agente")
    func shellWithOutput() {
        let activity = resolve(evidence(title: "⠋ tema", command: "zsh", knownAgent: .claude, outputAge: 1, screen: true))
        #expect(activity.state == .unknown)
        #expect(activity.agent == nil)
        #expect(activity.source == .title)
    }

    @Test("Sin IA identificable la salida no significa nada")
    func unknownAgentWithOutput() {
        let activity = resolve(evidence(title: "main.swift", command: "vim", outputAge: 1))
        #expect(activity.state == .unknown)
        #expect(activity.agent == nil)
        let remoteQuiet = resolve(evidence(title: "user@host", command: "ssh", outputAge: 10, screen: false))
        #expect(remoteQuiet.state == .unknown)
    }

    @Test("Un intérprete (node, python3) es IA viva sin nombre: la salida da working e idle")
    func agentRuntimeCommands() {
        let signal = AgentActivityTitleSignal(title: "Gemini CLI", currentCommand: "node")
        #expect(signal.isAgentRuntime)
        #expect(signal.agent == .gemini)
        let anonymous = AgentActivityTitleSignal(title: "host", currentCommand: "python3")
        #expect(anonymous.isAgentRuntime)
        #expect(anonymous.agent == nil)
        let working = resolve(evidence(title: "host", command: "python3", outputAge: 1))
        #expect(working.state == .working)
        #expect(working.agent == nil)
        let idle = resolve(evidence(title: "host", command: "node", outputAge: 9, screen: false))
        #expect(idle.state == .idle)
    }

    @Test("La conversación activa del registro local identifica al agente")
    func knownAgentFromRecord() {
        let activity = resolve(evidence(command: "python3", knownAgent: .agy, outputAge: 2))
        #expect(activity.state == .working)
        #expect(activity.agent == .agy)
    }

    // MARK: Regla 6: since

    @Test("since se conserva mientras el estado no cambia y se renueva al cambiar")
    func sinceTracksStateChanges() {
        let previous = AgentActivity(state: .working, source: .output, agent: .claude, since: now - 90)
        let same = resolve(evidence(command: "claude", outputAge: 1), previous: previous)
        #expect(same.state == .working)
        #expect(same.since == now - 90)
        let changed = resolve(evidence(command: "claude", outputAge: 30, screen: false), previous: previous)
        #expect(changed.state == .idle)
        #expect(changed.since == now)
    }

    // MARK: Hooks: texto de set_status y claves

    @Test("El texto de set_status se traduce a ciclo de vida")
    func statusTextMapsToLifecycle() {
        #expect(AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: "Idle") == .idle)
        #expect(AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: "Running") == .running)
        #expect(AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: "Needs input") == .needsInput)
        #expect(AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: "Permission required") == .needsInput)
        #expect(AgentActivityEvidence.Hooks.lifecycle(fromStatusValue: "Compilando") == .unknown)
        #expect(AgentActivity.Agent(hookKey: "claude_code") == .claude)
        #expect(AgentActivity.Agent(hookKey: "antigravity") == .agy)
        #expect(AgentActivity.Agent(hookKey: "cursor") == nil)
    }

    // MARK: Agregación por espacio

    @Test("waiting > working > idle > unknown")
    func aggregation() {
        func make(_ state: AgentActivity.State) -> AgentActivity {
            AgentActivity(state: state, source: .output, agent: nil, since: now)
        }
        #expect(AgentActivity.aggregateState([make(.idle), make(.working), make(.waiting)]) == .waiting)
        #expect(AgentActivity.aggregateState([make(.unknown), make(.working), make(.idle)]) == .working)
        #expect(AgentActivity.aggregateState([make(.unknown), make(.idle)]) == .idle)
        #expect(AgentActivity.aggregateState([make(.unknown)]) == .unknown)
        #expect(AgentActivity.aggregateState([AgentActivity]()) == .unknown)
    }

    // MARK: Sonda de tmux

    @Test("Las filas de list-panes se reparten por sesión y gana la más reciente")
    func tmuxRows() {
        let output = """
        uc-aaaa\tclaude\t✳ tema\t1800000100
        uc-aaaa\tzsh\t\t1800000050
        uc-bbbb\tcodex\t⠋ codex\t1800000200
        malformada
        """
        let rows = TmuxPaneActivityRow.parse(output)
        #expect(rows.count == 3)
        let bySession = TmuxPaneActivityRow.latestBySession(rows)
        #expect(bySession["uc-aaaa"]?.currentCommand == "claude")
        #expect(bySession["uc-aaaa"]?.title == "✳ tema")
        #expect(bySession["uc-aaaa"]?.windowActivity == 1_800_000_100)
        #expect(bySession["uc-bbbb"]?.currentCommand == "codex")
        #expect(bySession["uc-cccc"] == nil)
    }

    // MARK: Salida de la PTY

    @Test("El eco de teclado y los redibujados por tamaño no cuentan como salida")
    func outputCellFilters() {
        let cell = AgentOutputActivityCell()
        #expect(cell.snapshot().lastOutputAt == nil)
        cell.noteLocalInput(now: now)
        cell.noteOutput(byteCount: 3, now: now + 0.1)
        #expect(cell.snapshot().lastOutputAt == nil)
        cell.noteOutput(byteCount: 300, now: now + 1)
        #expect(cell.snapshot().lastOutputAt == now + 1)
        cell.noteResize(now: now + 2)
        cell.noteOutput(byteCount: 4_000, now: now + 2.2)
        #expect(cell.snapshot().lastOutputAt == now + 1)
        cell.noteOutput(byteCount: 0, now: now + 5)
        #expect(cell.snapshot().lastOutputAt == now + 1)
        cell.noteOutput(byteCount: 10, now: now + 5)
        #expect(cell.snapshot().lastOutputAt == now + 5)
    }

    // MARK: Contrato móvil

    @Test("El objeto activity del snapshot tiene la forma del contrato")
    func mobilePayload() {
        let activity = AgentActivity(state: .waiting, source: .screen, agent: .codex, since: now + 0.7)
        let payload = activity.mobilePayload
        #expect(payload["state"] as? String == "waiting")
        #expect(payload["source"] as? String == "screen")
        #expect(payload["agent"] as? String == "codex")
        #expect(payload["since"] as? Int == Int(now))
        let unevaluated = AgentActivity.unevaluated.mobilePayload
        #expect(unevaluated["state"] as? String == "unknown")
        #expect(unevaluated["agent"] is NSNull)
        #expect(unevaluated["since"] as? Int == 0)
        #expect(AgentActivity.mobileAggregatePayload(for: .working)["state"] as? String == "working")
    }
}
