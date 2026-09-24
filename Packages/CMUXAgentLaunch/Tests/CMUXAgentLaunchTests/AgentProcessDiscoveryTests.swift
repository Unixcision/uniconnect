import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Un solo criterio para saber qué IA corre en una ventana: el mismo en Mac, Linux y el VPS.
@Suite("Descubrimiento de la IA por proceso")
struct AgentProcessDiscoveryTests {
    private let claudeID = "714b0eae-b568-4e0c-a70b-c87c0d0a801a"
    private let otherID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
    private let codexID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"

    private func p(_ pid: Int, _ ppid: Int, _ argv: [String], uid: Int = 501) -> AgentProcessSample {
        AgentProcessSample(pid: pid, parentPID: ppid, userID: uid, arguments: argv)
    }

    private func discover(
        _ table: [AgentProcessSample],
        sessions: [Int: AgentClaudeSessionFile] = [:],
        openFiles: [Int: [String]] = [:],
        firstLines: [String: String] = [:],
        pane: Int = 100,
        cwd: String? = "/pane"
    ) -> AgentDiscoveryOutcome {
        AgentProcessDiscovery().discover(
            rootPID: pane,
            processes: table,
            claudeSession: { sessions[$0] },
            openFiles: openFiles,
            rolloutFirstLine: { firstLines[$0] },
            fallbackDirectory: cwd
        )
    }

    @Test("Cada caso del contrato da el mismo resultado")
    func everyContractCase() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/agent-tree-v1/deteccion-casos.json")
        guard let data = try? Data(contentsOf: url) else {
            // El paquete se compila también fuera del repo; sin el fichero no hay nada que comparar.
            return
        }
        let root = try JSONSerialization.jsonObject(with: data)
        let cases: [[String: Any]]
        if let list = root as? [[String: Any]] {
            cases = list
        } else if let object = root as? [String: Any],
                  let list = (object["casos"] ?? object["cases"]) as? [[String: Any]] {
            cases = list
        } else {
            Issue.record("forma desconocida de deteccion-casos.json")
            return
        }
        #expect(!cases.isEmpty)
        for entry in cases {
            let name = (entry["nombre"] ?? entry["name"] ?? entry["id"]) as? String ?? "?"
            let pane = try #require(Self.int(entry["pane_pid"] ?? entry["panePid"]), "\(name): pane_pid")
            let rows = try #require((entry["procesos"] ?? entry["processes"]) as? [[String: Any]], "\(name): procesos")
            let table = rows.compactMap { row -> AgentProcessSample? in
                guard let pid = Self.int(row["pid"]), let ppid = Self.int(row["ppid"] ?? row["parent_pid"]) else { return nil }
                let argv = (row["argv"] ?? row["args"]) as? [String] ?? []
                return AgentProcessSample(pid: pid, parentPID: ppid, userID: Self.int(row["uid"]) ?? 501, arguments: argv)
            }
            var sessions: [Int: AgentClaudeSessionFile] = [:]
            for (key, value) in ((entry["fichas"] ?? entry["claude_sessions"]) as? [String: [String: Any]]) ?? [:] {
                guard let pid = Int(key), let id = value["sessionId"] as? String else { continue }
                sessions[pid] = AgentClaudeSessionFile(
                    sessionId: id, cwd: value["cwd"] as? String, status: value["status"] as? String,
                    version: value["version"] as? String, procStart: value["procStart"] as? String
                )
            }
            var openFiles: [Int: [String]] = [:]
            for (key, value) in ((entry["abiertos"] ?? entry["open_files"]) as? [String: [String]]) ?? [:] {
                if let pid = Int(key) { openFiles[pid] = value }
            }
            let firstLines = ((entry["primeras_lineas"] ?? entry["rollout_first_lines"]) as? [String: String]) ?? [:]
            let cwd = (entry["pane_current_path"] ?? entry["cwd"]) as? String
            let outcome = discover(table, sessions: sessions, openFiles: openFiles, firstLines: firstLines, pane: pane, cwd: cwd)
            let expected = try #require((entry["esperado"] ?? entry["expected"]) as? [String: Any], "\(name): esperado")
            let reason = (expected["reason"] ?? expected["resultado"]) as? String
            if let reason, reason != "found", reason != "encontrada" {
                #expect(outcome.reason == reason, "\(name)")
                continue
            }
            guard case let .found(conversation) = outcome else {
                Issue.record("\(name): se esperaba una IA identificada y salió \(outcome)")
                continue
            }
            if let provider = (expected["provider"] ?? expected["proveedor"]) as? String {
                #expect(conversation.provider.rawValue == provider, "\(name)")
            }
            if let id = (expected["session_id"] ?? expected["sessionId"]) as? String {
                #expect(conversation.sessionID == id, "\(name)")
            }
            if let source = (expected["source"] ?? expected["fuente"]) as? String {
                #expect(conversation.source.rawValue == source, "\(name)")
            }
            if let asRoot = (expected["as_root"] ?? expected["como_root"]) as? Bool {
                #expect(conversation.asRoot == asRoot, "\(name)")
            }
            if let cwd = expected["cwd"] as? String {
                #expect(conversation.workingDirectory == cwd, "\(name)")
            }
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    @Test("Un shell sin hijos no tiene IA")
    func shellWithoutAgent() {
        #expect(discover([p(100, 1, ["-zsh"]), p(101, 100, ["vim", "x"])]) == .noAgent)
    }

    @Test("La ficha gana a la línea de órdenes tras /clear")
    func sessionFileBeatsArgv() {
        let outcome = discover(
            [p(100, 1, ["-zsh"]), p(200, 100, ["claude", "--resume", otherID, "--dangerously-skip-permissions"])],
            sessions: [200: AgentClaudeSessionFile(sessionId: claudeID, cwd: "/work", status: "idle", version: "2.1.280")]
        )
        #expect(outcome == .found(AgentObservedConversation(
            provider: .claude, sessionID: claudeID, workingDirectory: "/work", asRoot: false,
            source: .sessionFile, status: "idle", version: "2.1.280", processID: 200
        )))
    }

    @Test("Sin ficha, Claude se identifica por --resume y se marca como argv")
    func claudeFromArgv() {
        let outcome = discover([p(100, 1, ["zsh"]), p(200, 100, ["/opt/homebrew/bin/claude", "-r", otherID.uppercased()])])
        guard case let .found(conversation) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(conversation.sessionID == otherID)
        #expect(conversation.source == .argv)
        #expect(conversation.workingDirectory == "/pane")
    }

    @Test("Claude sin id todavía queda sin_id")
    func claudeWithoutID() {
        #expect(discover([p(100, 1, ["zsh"]), p(200, 100, ["claude", "login"])]) == .unidentified(.claude, processID: 200))
    }

    @Test("Claude bajo sudo como root sigue siendo una sola IA y va como root")
    func claudeUnderSudo() {
        let outcome = discover([
            p(100, 1, ["bash"], uid: 0),
            p(150, 100, ["sudo", "-E", "claude"], uid: 0),
            p(200, 150, ["claude", "--resume", claudeID], uid: 0),
        ])
        guard case let .found(conversation) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(conversation.asRoot)
        #expect(conversation.processID == 200)
    }

    @Test("Codex bajo node con el binario nativo de nieto cuenta como una raíz y lee su rollout")
    func codexUnderNode() {
        let rollout = "/Users/u/.codex/sessions/2026/09/24/rollout-2026-09-24T14-30-05-\(codexID).jsonl"
        let outcome = discover(
            [
                p(100, 1, ["-zsh"]),
                p(200, 100, ["node", "/opt/homebrew/bin/codex", "--yolo"]),
                p(201, 200, ["/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex-aarch64-apple-darwin", "--yolo"]),
            ],
            openFiles: [201: ["/dev/ttys001", rollout]],
            firstLines: [rollout: #"{"type":"session_meta","payload":{"id":"x","cwd":"/Users/u/multigram"}}"#]
        )
        #expect(outcome == .found(AgentObservedConversation(
            provider: .codex, sessionID: codexID, workingDirectory: "/Users/u/multigram", asRoot: false,
            source: .rollout, processID: 200
        )))
    }

    @Test("Codex sin rollout abierto usa `resume <uuid>` de la línea de órdenes")
    func codexFromArgv() {
        let outcome = discover([p(100, 1, ["zsh"]), p(200, 100, ["codex", "--yolo", "resume", codexID])])
        guard case let .found(conversation) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(conversation.source == .argv)
        #expect(conversation.sessionID == codexID)
    }

    @Test("Un codex nuevo antes de su primer turno queda sin_id")
    func freshCodex() {
        #expect(discover([p(100, 1, ["zsh"]), p(200, 100, ["codex"])]) == .unidentified(.codex, processID: 200))
    }

    @Test("Un codex lanzado por la herramienta Bash de Claude no es raíz")
    func codexUnderClaudeIsNotARoot() {
        let outcome = discover(
            [
                p(100, 1, ["zsh"]),
                p(200, 100, ["claude"]),
                p(300, 200, ["/bin/bash", "-c", "codex exec hola"]),
                p(301, 300, ["codex", "exec", "hola"]),
            ],
            sessions: [200: AgentClaudeSessionFile(sessionId: claudeID)]
        )
        guard case let .found(conversation) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(conversation.provider == .claude)
    }

    @Test("Dos claude hermanos son ambiguos")
    func twoClaudesAreAmbiguous() {
        #expect(discover([
            p(100, 1, ["zsh"]),
            p(200, 100, ["claude", "--resume", claudeID]),
            p(201, 100, ["claude", "--resume", otherID]),
        ]) == .ambiguous)
    }

    @Test("Un proceso de fuera del subárbol no cuenta aunque sea Claude")
    func outsideTheSubtreeDoesNotCount() {
        #expect(discover([p(100, 1, ["zsh"]), p(900, 1, ["claude", "--resume", claudeID])]) == .noAgent)
    }

    @Test("agy y grok se leen de sus opciones")
    func agyAndGrok() {
        let agy = discover([p(100, 1, ["zsh"]), p(200, 100, ["agy", "--dangerously-skip-permissions", "--conversation", "conv-1"])])
        let grok = discover([p(100, 1, ["zsh"]), p(200, 100, ["grok", "-r", "g-1"])])
        guard case let .found(a) = agy, case let .found(g) = grok else {
            Issue.record("\(agy) \(grok)")
            return
        }
        #expect(a.provider == .agy && a.sessionID == "conv-1")
        #expect(g.provider == .grok && g.sessionID == "g-1")
    }

    @Test("Node sin marca, sudo y env no son IA")
    func unmarkedProcessesAreNotAgents() {
        for argv in [["node", "server.js"], ["sudo", "ls"], ["env", "A=1", "top"], ["login", "-pf", "u"]] {
            #expect(AgentObservedProvider.classify(p(1, 0, argv), hasClaudeSession: false) == nil, "\(argv)")
        }
        #expect(AgentObservedProvider.classify(p(1, 0, ["node", "/x/@anthropic-ai/claude-code/cli.js"]), hasClaudeSession: false) == .claude)
        #expect(AgentObservedProvider.classify(p(1, 0, ["/Users/u/.local/share/claude/versions/2.1.280"]), hasClaudeSession: false) == .claude)
        #expect(AgentObservedProvider.classify(p(1, 0, ["codex-x86_64-unknown-linux-musl"]), hasClaudeSession: false) == .codex)
    }

    @Test("El rollout solo vale con su nombre y su carpeta")
    func rolloutNames() {
        #expect(AgentProcessDiscovery.rolloutID(path: "/h/.codex/sessions/2026/09/24/rollout-2026-09-24T14-30-05-\(codexID.uppercased()).jsonl") == codexID)
        #expect(AgentProcessDiscovery.rolloutID(path: "/tmp/rollout-2026-\(codexID).jsonl") == nil)
        #expect(AgentProcessDiscovery.rolloutID(path: "/h/.codex/sessions/rollout-x.jsonl") == nil)
    }

    @Test("Se ignora la ficha de un pid muerto o de un proceso que no es Claude")
    func staleSessionFilesAreIgnored() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-discovery-\(UUID().uuidString)", isDirectory: true)
        let sessions = folder.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for pid in [200, 300, 400] {
            let body = #"{"pid":\#(pid),"sessionId":"\#(claudeID)","cwd":"/w","procStart":"Wed Sep 23 16:38:01 2026","status":"idle","extra":{"a":1}}"#
            try Data(body.utf8).write(to: sessions.appendingPathComponent("\(pid).json"))
        }
        try Data(String(repeating: "x", count: AgentClaudeSessionFile.maximumSize + 1).utf8)
            .write(to: sessions.appendingPathComponent("500.json"))
        // 200 es Claude vivo; 300 murió; 400 es un pid reciclado por otro programa.
        let directory = AgentClaudeSessionDirectory(root: folder, isLiveClaude: { $0 == 200 || $0 == 500 })
        #expect(directory.file(pid: 200)?.sessionId == claudeID)
        #expect(directory.file(pid: 200)?.procStart == "Wed Sep 23 16:38:01 2026")
        #expect(directory.file(pid: 300) == nil)
        #expect(directory.file(pid: 400) == nil)
        #expect(directory.file(pid: 500) == nil)
        #expect(directory.liveHolders(sessionID: claudeID.uppercased()) == [200])
        #expect(directory.liveHolders(sessionID: otherID).isEmpty)
    }

    @Test("La profundidad y el número de nodos están acotados")
    func subtreeIsBounded() {
        var table = [p(100, 1, ["zsh"])]
        for level in 1...20 { table.append(p(100 + level, 99 + level, ["sh"])) }
        table.append(p(200, 120, ["claude", "--resume", claudeID]))
        #expect(discover(table) == .noAgent)
        #expect(AgentProcessDiscovery().subtree(rootPID: 100, processes: table).count == 9)
    }
}
