import CmuxProcess
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Lógica pura de la actividad de IA (`activity.v1`): título, pantalla, prioridad de
/// fuentes, agregación por espacio, sonda de tmux, filtro de eco y rachas de salida.
@Suite("Actividad de IA")
struct AgentActivityResolverTests {
    private let now: TimeInterval = 1_800_000_000
    private let resolver = AgentActivityResolver()

    /// `outputRun` es lo que lleva escribiendo la racha que acaba hace `outputAge` segundos;
    /// `0` es una ráfaga suelta. `output` sustituye a ambos (por ejemplo, una celda real).
    private func evidence(
        hooks: AgentActivityEvidence.Hooks? = nil,
        title: String? = nil,
        command: String? = nil,
        knownAgent: AgentActivity.Agent? = nil,
        outputAge: TimeInterval? = nil,
        outputRun: TimeInterval = 0,
        output: AgentActivityEvidence.Output? = nil,
        screen: Bool? = nil
    ) -> AgentActivityEvidence {
        let lastOutputAt = outputAge.map { now - $0 }
        return AgentActivityEvidence(
            hooks: hooks,
            title: AgentActivityEvidence.Title(text: title, currentCommand: command),
            knownAgent: knownAgent,
            output: output ?? AgentActivityEvidence.Output(
                lastOutputAt: lastOutputAt,
                runStartedAt: lastOutputAt.map { $0 - outputRun }
            ),
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

    @Test("Un running de los hooks de más de 120 s se ignora")
    func staleRunningHooksIgnored() {
        let hooks = AgentActivityEvidence.Hooks(lifecycle: .running, agent: .codex, reportedAt: now - 200)
        let activity = resolve(evidence(hooks: hooks, title: "⠋ codex", command: "codex"))
        #expect(activity.state == .working)
        #expect(activity.source == .title)
        let quiet = resolve(evidence(hooks: hooks, command: "codex", outputAge: 30, screen: false))
        #expect(quiet.state == .idle)
        #expect(quiet.source == .output)
    }

    @Test("Un idle o needsInput de los hooks de hace 10 min aguanta una ráfaga y el título")
    func stickyHooksSurviveBursts() {
        let idle = AgentActivityEvidence.Hooks(lifecycle: .idle, agent: .claude, reportedAt: now - 600)
        let burst = resolve(evidence(hooks: idle, title: "✳ tema", command: "claude", outputAge: 0.2, outputRun: 0.05))
        #expect(burst.state == .idle)
        #expect(burst.source == .hooks)
        #expect(burst.agent == .claude)
        let shortRun = resolve(evidence(hooks: idle, command: "claude", outputAge: 0.5, outputRun: 2))
        #expect(shortRun.state == .idle)
        let spinner = resolve(evidence(hooks: idle, title: "⠋ codex", command: "codex", outputAge: 0.5))
        #expect(spinner.state == .idle)
        let needsInput = AgentActivityEvidence.Hooks(lifecycle: .needsInput, agent: .claude, reportedAt: now - 600)
        let waiting = resolve(evidence(hooks: needsInput, command: "claude", outputAge: 0.2, outputRun: 0.05))
        #expect(waiting.state == .waiting)
        #expect(waiting.source == .hooks)
    }

    @Test("Solo una racha de 3 s vence a un idle o needsInput de los hooks")
    func sustainedOutputOverridesStickyHooks() {
        for lifecycle in [AgentHibernationLifecycleState.idle, .needsInput] {
            let hooks = AgentActivityEvidence.Hooks(lifecycle: lifecycle, agent: .claude, reportedAt: now - 600)
            let activity = resolve(evidence(hooks: hooks, command: "claude", outputAge: 0.3, outputRun: 3.5))
            #expect(activity.state == .working)
            #expect(activity.source == .output)
            #expect(activity.agent == .claude)
        }
    }

    @Test("Un idle de los hooks deja de contar cuando la IA muere y queda un shell")
    func stickyHooksEndWithTheProcess() {
        let hooks = AgentActivityEvidence.Hooks(lifecycle: .idle, agent: .claude, reportedAt: now - 600)
        let activity = resolve(evidence(hooks: hooks, title: "✳ tema", command: "zsh", outputAge: 30))
        #expect(activity.state == .unknown)
        #expect(activity.agent == nil)
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
        let working = resolve(evidence(title: "✳ tema", command: "claude", outputAge: 1, outputRun: 2))
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
        let working = resolve(evidence(title: "host", command: "python3", outputAge: 1, outputRun: 2))
        #expect(working.state == .working)
        #expect(working.agent == nil)
        let idle = resolve(evidence(title: "host", command: "node", outputAge: 9, screen: false))
        #expect(idle.state == .idle)
    }

    @Test("La conversación activa del registro local identifica al agente")
    func knownAgentFromRecord() {
        let activity = resolve(evidence(command: "python3", knownAgent: .agy, outputAge: 2, outputRun: 2))
        #expect(activity.state == .working)
        #expect(activity.agent == .agy)
    }

    // MARK: Regla 6: since

    @Test("since se conserva mientras el estado no cambia y se renueva al cambiar")
    func sinceTracksStateChanges() {
        let previous = AgentActivity(state: .working, source: .output, agent: .claude, since: now - 90)
        let same = resolve(evidence(command: "claude", outputAge: 1, outputRun: 2), previous: previous)
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

    @Test("Una ráfaga suelta (redibujado de tmux) no despierta a una IA parada")
    func loneBurstIsNotWork() {
        let cell = AgentOutputActivityCell()
        cell.noteOutput(byteCount: 724, now: now - 0.30)
        cell.noteOutput(byteCount: 312, now: now - 0.25)
        let output = AgentActivityEvidence.Output(cell.snapshot())
        #expect(output.runStartedAt == now - 0.30)
        let idle = AgentActivity(state: .idle, source: .output, agent: .claude, since: now - 600)
        for previous in [nil, idle] {
            let activity = resolve(evidence(title: "✳ tema", command: "claude", output: output), previous: previous)
            #expect(activity.state == .idle)
            #expect(activity.since == previous?.since ?? now)
        }
    }

    @Test("La salida sostenida de una IA que trabaja es working")
    func sustainedOutputIsWork() {
        let cell = AgentOutputActivityCell()
        let start = now - 1.6
        for step in 0...15 {
            cell.noteOutput(byteCount: 4_000, now: start + Double(step) * 0.1)
        }
        let output = AgentActivityEvidence.Output(cell.snapshot())
        #expect(output.runStartedAt == start)
        #expect(output.runDuration >= 1)
        let activity = resolve(evidence(title: "✳ tema", command: "claude", output: output))
        #expect(activity.state == .working)
        #expect(activity.source == .output)
    }

    @Test("Un hueco de más de 1 s corta la racha y lo que sigue vuelve a ser una ráfaga")
    func gapBreaksTheRun() {
        let cell = AgentOutputActivityCell()
        let start = now - 6
        for step in 0...14 {
            cell.noteOutput(byteCount: 2_000, now: start + Double(step) * 0.1)
        }
        cell.noteOutput(byteCount: 2_000, now: start + 2.3)
        #expect(cell.snapshot().runStartedAt == start)
        let burst = now - 0.5
        cell.noteOutput(byteCount: 312, now: burst)
        let snapshot = cell.snapshot()
        #expect(snapshot.runStartedAt == burst)
        #expect(snapshot.lastOutputAt == burst)
        let idle = AgentActivity(state: .idle, source: .output, agent: .claude, since: now - 60)
        let activity = resolve(evidence(command: "claude", output: AgentActivityEvidence.Output(snapshot)), previous: idle)
        #expect(activity.state == .idle)
    }

    @Test("Con tmux local manda window_activity: una PTY fresca con window_activity viejo es idle")
    func tmuxWindowIgnoresTheTee() async {
        let probe = TmuxPaneActivityProbe(commands: ProbeCommands(outputs: [
            "uc-aaaa\tclaude\t✳ tema\t\(Int(now) - 600)\n",
        ]))
        let monitor = AgentActivityMonitor(probe: probe)
        let workspaceID = UUID(), panelID = UUID()
        // La PTY es un cliente `tmux attach`: ve redibujados aunque el panel no escriba.
        let tee = AgentActivityEvidence.Output(lastOutputAt: now - 0.2, runStartedAt: now - 2.5)
        let input = AgentActivityTerminalInput(
            workspaceID: workspaceID,
            panelID: panelID,
            tmux: .init(socketName: "test-local", sessionName: "uc-aaaa"),
            evidence: AgentActivityEvidence(output: tee)
        )
        let result = await monitor.evaluate(inputs: [input], now: now) { _ in false }
        let activity = result[workspaceID]?[panelID]
        #expect(activity?.state == .idle)
        #expect(activity?.agent == .claude)
    }

    @Test("Con tmux la racha se reconstruye entre muestras y un hueco la corta")
    func tmuxSampledRuns() async {
        let start = Int(now)
        let samples = [start, start + 2, start + 2, start + 12, start + 14]
        let probe = TmuxPaneActivityProbe(commands: ProbeCommands(outputs: samples.map {
            "uc-aaaa\tclaude\t✳ tema\t\($0)\n"
        }))
        let monitor = AgentActivityMonitor(probe: probe)
        let workspaceID = UUID(), panelID = UUID()
        let input = AgentActivityTerminalInput(
            workspaceID: workspaceID,
            panelID: panelID,
            tmux: .init(socketName: "test-local", sessionName: "uc-aaaa"),
            evidence: AgentActivityEvidence()
        )
        var states: [AgentActivity.State?] = []
        for at in [now, now + 2, now + 10, now + 12, now + 14] {
            let result = await monitor.evaluate(inputs: [input], now: at) { _ in false }
            states.append(result[workspaceID]?[panelID]?.state)
        }
        // 1.ª muestra: una sola marca es una ráfaga. 2.ª: actividad seguida, working.
        // 3.ª: 8 s sin salida, idle. 4.ª: tras el hueco la racha vuelve a empezar. 5.ª: sigue.
        #expect(states == [.idle, .working, .idle, .idle, .working])
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

    /// Ejecutor falso de la sonda de tmux: devuelve una salida de `list-panes` por llamada.
    private actor ProbeCommands: CommandRunning {
        private var outputs: [String]

        init(outputs: [String]) {
            self.outputs = outputs
        }

        func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
            let output = outputs.isEmpty ? nil : outputs.removeFirst()
            return CommandResult(stdout: output, stderr: nil, exitStatus: output == nil ? 1 : 0, timedOut: false, executionError: nil)
        }
    }
}
