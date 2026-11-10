import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// El Claude local con las reglas del 08-11 y el 09-11, contra un tmux y una tabla de procesos de
/// mentira que se comportan como los de verdad: `/exit` sobre un borrador lo enviaría, así que eso
/// es lo primero que se comprueba.
@Suite("Claude local: relanzar y actualizar", .serialized)
struct UniConnectRelaunchLocalClaudeTests {
    private static let session = "57c82fdd-78cb-4a6d-8ef9-f80553c0493a"
    private static let t0 = Date(timeIntervalSince1970: 1_794_256_673.5)
    private static let t1 = Date(timeIntervalSince1970: 1_794_256_900.25)

    /// Una tabla de procesos de mentira; sus señales y salidas cambian la tabla como el núcleo.
    final class Processes: UniConnectRelaunchProcessInspecting, @unchecked Sendable {
        // Las pruebas son secuenciales (`.serialized`): no hay acceso concurrente real.
        var table: [UniConnectRelaunchProcessInfo] = []
        var argv: [Int32: [String]] = [:]
        var environment: [Int32: [String: String]] = [:]
        var signals: [String] = []

        func processes() -> [UniConnectRelaunchProcessInfo]? { table }
        func arguments(of pid: Int32) -> (argv: [String], environment: [String: String])? {
            argv[pid].map { ($0, environment[pid] ?? [:]) }
        }
        func workingDirectory(of pid: Int32) -> String? { "/tmp/proyecto" }
        func executablePath(of pid: Int32) -> String? {
            table.first(where: { $0.pid == pid })?.name == "claude"
                ? "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" : "/bin/zsh"
        }
        func signal(_ signal: Int32, to pid: Int32) -> Bool {
            signals.append("\(signal)>\(pid)")
            table.removeAll { $0.pid == pid }
            return true
        }
        func signal(_ signal: Int32, toGroup group: Int32) -> Bool {
            signals.append("\(signal)>grupo \(group)")
            table.removeAll { $0.group == group }
            return true
        }
        func waitForExit(of pid: Int32, timeout: Duration) async -> Bool { !table.contains { $0.pid == pid } }
    }

    /// Un panel de tmux de mentira: un compositor de Claude o un shell, y lo que se le escribe.
    final class Pane: UniConnectRelaunchPaneAccess, @unchecked Sendable {
        var composer = ""
        var atShell = false
        var trust = false
        var trustSelection = 0
        var log: [String] = []
        var submitted: [String] = []
        var onExit: () -> Void = {}
        var onReopen: () -> Void = {}
        /// Whether the shell has nothing left under it, as the process table says.
        var shellIdle: () -> Bool = { false }

        func firstPane(socket: String, session: String) async -> String? { "%1" }
        func panePID(socket: String, pane: String) async -> Int32? { 100 }
        func agent(socket: String, pane: String, provider: String) async -> UniConnectRelaunchAgentLookup { .noAgent }
        func capture(socket: String, pane: String) async -> String? { render() }
        func screen(socket: String, pane: String) async -> RelaunchPaneScreen? {
            RelaunchPaneScreen(text: render(plain: true), cursorRow: 0, cursorColumn: 0, styledText: render())
        }
        func type(socket: String, pane: String, text: String) async {
            log.append("type:\(text)")
            if atShell || shellIdle() {
                atShell = false
                composer = ""
                onReopen()
            }
        }
        func typeLiteral(socket: String, pane: String, text: String) async {
            log.append("literal:\(text)")
            composer += text
        }
        func pressEnter(socket: String, pane: String) async {
            log.append("enter")
            if trust {
                if trustSelection == 1 { trust = false }
                return
            }
            if composer == "/exit" {
                composer = ""
                atShell = true
                onExit()
            } else if !composer.isEmpty {
                submitted.append(composer)
                composer = ""
            }
        }
        func pressKey(socket: String, pane: String, key: String) async {
            log.append("key:\(key)")
            if key == "Down" { trustSelection = min(1, trustSelection + 1) }
        }
        func isAtShell(socket: String, pane: String) async -> Bool { atShell || shellIdle() }
        func respawnShell(socket: String, pane: String, directory: String) async -> Bool {
            log.append("respawn")
            atShell = true
            return true
        }

        private func render(plain: Bool = false) -> String {
            let rule = String(repeating: "─", count: 40)
            if atShell || shellIdle() { return "danielgomezmartin@Mac proyecto % " }
            if trust {
                return [" Accessing workspace:", " /tmp/proyecto", "",
                        trustSelection == 0 ? " ❯ No, exit" : "   No, exit",
                        trustSelection == 1 ? " ❯ Yes, I trust this folder" : "   Yes, I trust this folder",
                        " Enter to confirm · Esc to cancel"].joined(separator: "\n")
            }
            let line = composer.isEmpty
                ? (plain ? "❯ Try \"refactor <filepath>\"" : "❯ \u{1B}[2mTry \"refactor <filepath>\"\u{1B}[0m")
                : "❯ " + composer
            return [" ▐▛███▜▌   Claude Code v2.1.321", rule, line, rule, "  ⏵⏵ bypass permissions on"].joined(separator: "\n")
        }
    }

    private struct Fixture {
        let home: URL
        let processes = Processes()
        let pane = Pane()
        var claude: UniConnectRelaunchLocalClaude {
            UniConnectRelaunchLocalClaude(
                panes: pane, processes: processes,
                archive: UniConnectRelaunchMonitorArchive(root: home.appendingPathComponent("monitores")),
                home: home, directoryExists: { _ in true }, isExecutable: { $0 == "/usr/local/bin/claude" },
                now: { Date(timeIntervalSince1970: 1_794_257_000) }, settle: {}
            )
        }
        var key: RelaunchTargetKey {
            RelaunchTargetKey(destination: .local(machineID: "mac"), tmuxServer: "uniconnect-local", pane: "uc-x", generation: 1)
        }

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("uc-relanzar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true)
            processes.table = [
                .init(pid: 100, parent: 50, group: 100, userID: 501, start: Date(timeIntervalSince1970: 1_794_000_000), name: "zsh"),
            ]
            processes.argv[100] = ["-zsh"]
            pane.shellIdle = { [processes] in !processes.table.contains { $0.parent == 100 } }
        }

        func addClaude(pid: Int32, start: Date, status: String = "idle", fichaStart: Date? = nil, session: String = UniConnectRelaunchLocalClaudeTests.session, parent: Int32 = 100) throws {
            processes.table.append(.init(pid: pid, parent: parent, group: pid, userID: 501, start: start, name: "claude"))
            processes.argv[pid] = ["claude", "--resume", session, "--dangerously-skip-permissions", "--model", "fable[1m]", "--effort", "medium"]
            processes.environment[pid] = ["PATH": "/usr/local/bin:/usr/bin"]
            let ficha: [String: Any] = [
                "pid": Int(pid), "sessionId": session, "cwd": "/tmp/proyecto", "status": status, "version": "2.1.321",
                "startedAt": ((fichaStart ?? start).timeIntervalSince1970 * 1000).rounded(),
            ]
            try JSONSerialization.data(withJSONObject: ficha)
                .write(to: home.appendingPathComponent(".claude/sessions/\(pid).json"))
        }

        func addMonitor(pid: Int32, parent: Int32) {
            processes.table.append(.init(pid: pid, parent: parent, group: pid, userID: 501, start: UniConnectRelaunchLocalClaudeTests.t0, name: "zsh"))
            processes.argv[pid] = ["/bin/zsh", "-c", "source /Users/d/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'tail -n0 -F /tmp/uc-prueba.log | grep --line-buffered HOLA' < /dev/null && pwd -P >| /tmp/claude-501/cwd"]
        }

        /// Al reabrir aparece un Claude nuevo con su ficha.
        func reopensAs(pid: Int32) {
            pane.onReopen = { [processes, home] in
                processes.table.append(.init(pid: pid, parent: 100, group: pid, userID: 501, start: UniConnectRelaunchLocalClaudeTests.t1, name: "claude"))
                processes.argv[pid] = ["claude", "--resume", UniConnectRelaunchLocalClaudeTests.session]
                let ficha: [String: Any] = ["pid": Int(pid), "sessionId": UniConnectRelaunchLocalClaudeTests.session, "status": "idle",
                                            "version": "2.1.330", "startedAt": (UniConnectRelaunchLocalClaudeTests.t1.timeIntervalSince1970 * 1000).rounded()]
                try? JSONSerialization.data(withJSONObject: ficha).write(to: home.appendingPathComponent(".claude/sessions/\(pid).json"))
            }
        }

        func proof(_ verb: RelaunchVerb = .agentRelaunch) async throws -> (UniConnectRelaunchLocalClaudeProof, RelaunchTargetNotes) {
            guard case let .proof(proof, notes) = await claude.inspect(socket: "uniconnect-local", session: "uc-x", verb: verb) else {
                Issue.record("no se acreditó el Claude")
                throw CancellationError()
            }
            return (proof, notes)
        }
    }

    @Test("Con un borrador NUNCA se escribe /exit: se para el grupo de Claude y el borrador vuelve sin Intro")
    func aDraftIsNeverSubmitted() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0)
        fixture.pane.composer = "hola esto es un borrador"
        fixture.reopensAs(pid: 300)
        let (proof, notes) = try await fixture.proof()
        #expect(notes.draft == true)
        #expect(notes.message == false)

        let result = await fixture.claude.relaunch(
            key: fixture.key, socket: "uniconnect-local", session: "uc-x", proof: proof, verb: .agentRelaunch, options: .unchanged
        )

        #expect(result.state == .verified)
        #expect(result.effectiveID == Self.session)
        #expect(result.escalation == .killProcess)
        #expect(!fixture.pane.log.contains("literal:/exit"))
        #expect(fixture.pane.submitted.isEmpty, "el borrador o algo se envió: \(fixture.pane.submitted)")
        #expect(fixture.processes.signals.first == "\(SIGTERM)>grupo 200")
        #expect(!fixture.processes.signals.contains { $0.hasSuffix(">100") || $0.hasSuffix("grupo 100") }, "se tocó el shell del panel")
        #expect(fixture.pane.log.contains("type:cd /tmp/proyecto && claude --resume \(Self.session) --dangerously-skip-permissions --model 'fable[1m]' --effort medium"))
        #expect(result.draftRestored == true)
        #expect(result.messageSent == false)
        #expect(fixture.pane.composer == "hola esto es un borrador")
        #expect(fixture.pane.log.last == "literal:hola esto es un borrador")
    }

    @Test("Ocioso y vacío sale con /exit; los monitores se guardan, se paran y se le cuentan en el único mensaje")
    func cleanExitWithMonitors() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0)
        fixture.addMonitor(pid: 210, parent: 200)
        fixture.pane.onExit = { [processes = fixture.processes] in
            processes.table.removeAll { $0.pid == 200 }
            if let index = processes.table.firstIndex(where: { $0.pid == 210 }) {
                let monitor = processes.table[index]
                processes.table[index] = .init(pid: 210, parent: 1, group: 210, userID: 501, start: monitor.start, name: "zsh")
            }
        }
        fixture.reopensAs(pid: 300)
        let (proof, notes) = try await fixture.proof(.agentUpdate)
        #expect(notes.background == 1)
        #expect(notes.warning == .backgroundTasks)
        #expect(notes.message == true)
        #expect(notes.version == "2.1.321")

        let result = await fixture.claude.relaunch(
            key: fixture.key, socket: "uniconnect-local", session: "uc-x", proof: proof, verb: .agentUpdate,
            options: try RelaunchUpdateOptions(model: "opus[1m]", effort: nil)
        )

        #expect(result.state == .verified)
        #expect(result.escalation == .exit)
        #expect(result.backgroundSaved == 1)
        #expect(result.messageSent == true)
        #expect(result.model == "opus[1m]")
        #expect(result.effort == "medium")
        #expect(result.version == "2.1.330")
        #expect(fixture.processes.signals == ["\(SIGTERM)>210"], "el monitor huérfano tiene que pararse, y solo él")
        let message = try #require(fixture.pane.submitted.first)
        #expect(message.hasPrefix("UniConnect te ha reiniciado para actualizar Claude Code a 2.1.330. Al cerrar se pararon tus 1 monitores"))
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.home.appendingPathComponent("monitores").path)
        let saved = try #require(files.first { $0.hasSuffix(".txt") })
        #expect(message.contains(saved))
        let text = try String(contentsOf: fixture.home.appendingPathComponent("monitores/\(saved)"), encoding: .utf8)
        #expect(text.hasPrefix("# sesion=uc-x conversacion=\(Self.session) estado=idle fecha=2026-"))
        #expect(text.contains("# Monitor o shell de fondo 1\ntail -n0 -F /tmp/uc-prueba.log | grep --line-buffered HOLA\n"))
        #expect(saved.hasPrefix(Self.session + "-"))
        #expect(fixture.pane.log.contains("type:cd /tmp/proyecto && claude --resume \(Self.session) --dangerously-skip-permissions --effort medium --model 'opus[1m]'"))
    }

    @Test("Una ficha de otro arranque con el PID reutilizado es identidad_ambigua y no se toca nada")
    func staleFichaIsAmbiguous() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0, fichaStart: Self.t0.addingTimeInterval(-3600))
        let inspection = await fixture.claude.inspect(socket: "uniconnect-local", session: "uc-x", verb: .agentRelaunch)
        #expect(inspection == .excluded(.ambiguousIdentity))
        #expect(fixture.pane.log.isEmpty)
    }

    @Test("Dos Claude vivos en la misma conversación: conversacion_compartida")
    func sharedConversationIsExcluded() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0)
        try fixture.addClaude(pid: 400, start: Self.t1, parent: 999)
        let inspection = await fixture.claude.inspect(socket: "uniconnect-local", session: "uc-x", verb: .agentRelaunch)
        #expect(inspection == .excluded(.sharedConversation))
    }

    @Test("Trabajando es un aviso y no se teclea nada: se para el proceso y se le dice que siga")
    func busyIsAWarningAndGetsTheMessage() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0, status: "busy")
        fixture.reopensAs(pid: 300)
        let (proof, notes) = try await fixture.proof()
        #expect(notes.warning == .backgroundTasks)
        #expect(notes.message == true)
        let result = await fixture.claude.relaunch(
            key: fixture.key, socket: "uniconnect-local", session: "uc-x", proof: proof, verb: .agentRelaunch, options: .unchanged
        )
        #expect(result.state == .verified)
        #expect(result.escalation == .killProcess)
        #expect(!fixture.pane.log.contains("literal:/exit"))
        #expect(fixture.pane.submitted == ["UniConnect te ha reiniciado para relanzarte mientras trabajabas, así que lo que tenías en marcha se cortó a medias. Retómalo justo donde se quedó."])
    }

    @Test("La confianza de la misma carpeta se contesta por su texto, bajando hasta «Yes, I trust this folder»")
    func trustForTheSameFolderIsAnsweredByText() async throws {
        let fixture = try Fixture()
        try fixture.addClaude(pid: 200, start: Self.t0)
        fixture.pane.onExit = { [processes = fixture.processes] in processes.table.removeAll { $0.pid == 200 } }
        let reopen: () -> Void = { [pane = fixture.pane] in pane.trust = true }
        fixture.reopensAs(pid: 300)
        let previous = fixture.pane.onReopen
        fixture.pane.onReopen = { previous(); reopen() }
        let (proof, _) = try await fixture.proof()

        let result = await fixture.claude.relaunch(
            key: fixture.key, socket: "uniconnect-local", session: "uc-x", proof: proof, verb: .agentRelaunch, options: .unchanged
        )

        #expect(result.state == .verified)
        let down = try #require(fixture.pane.log.firstIndex(of: "key:Down"))
        let enter = try #require(fixture.pane.log.lastIndex(of: "enter"))
        #expect(down < enter)
        #expect(fixture.pane.submitted.isEmpty)
    }

    @Test("argv real de KERN_PROCARGS2, con un argumento vacío en medio")
    func procArgsKeepEmptyArguments() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(4).littleEndian) { bytes.append(contentsOf: $0) }
        let strings = ["/usr/local/bin/claude"]
        for text in strings { bytes += Array(text.utf8) + [0] }
        bytes += [0, 0, 0]
        for text in ["claude", "--settings", "", "--chrome"] { bytes += Array(text.utf8) + [0] }
        for text in ["PATH=/usr/bin", "IS_SANDBOX=1"] { bytes += Array(text.utf8) + [0] }
        bytes += [0] + Array("executable_path=/x".utf8) + [0]
        let parsed = try #require(UniConnectRelaunchProcArgs(bytes: bytes))
        #expect(parsed.argv == ["claude", "--settings", "", "--chrome"])
        #expect(parsed.environment == ["PATH": "/usr/bin", "IS_SANDBOX": "1"])
    }
}
