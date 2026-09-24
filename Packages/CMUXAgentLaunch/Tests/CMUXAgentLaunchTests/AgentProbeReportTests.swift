import Foundation
import Testing
@testable import CMUXAgentLaunch

/// La salida de la sonda remota se lee igual en el Mac que en Linux: la fijan
/// `contracts/agent-tree-v1/sonda-salida.json` y `sonda-lectura.json`.
@Suite("Informe de la sonda remota")
struct AgentProbeReportTests {
    @Test("Decodifica el ejemplo del contrato tal y como lo emite agent_probe.py")
    func decodesTheContractExample() throws {
        let data = try ContractFixtures().data("agent-tree-v1/sonda-salida.json")
        let report = try #require(AgentProbeReport.decode(output: data))
        #expect(report.version == 1)
        #expect(report.error == nil)
        #expect(report.uid == 0)
        #expect(report.socket == "default")
        #expect(report.server)
        #expect(!report.truncated)
        #expect(report.missingMeansGone)
        let claude = try #require(report.session(named: "claudebets"))
        #expect(claude.agent?.provider == "claude")
        #expect(claude.agent?.sessionID == "473ed1de-4397-45ef-b00b-6b17fd7382b0")
        #expect(claude.agent?.asRoot == true)
        #expect(claude.agent?.source == "ficha")
        #expect(claude.sessionID == "$0")
        #expect(claude.paneID == "%0")
        let noID = try #require(report.session(named: "ufabetbot"))
        #expect(noID.reason == "sin_id")
        #expect(noID.agent?.sessionID == nil)
        // Un panel muerto sigue siendo su sesión: se lee, pero no cambia nada guardado.
        let dead = try #require(report.session(named: "caida"))
        #expect(dead.reason == "panel_muerto")
        #expect(dead.isDeadPane)
        #expect(dead.effect == .nothing)
        // La sesión de dos paneles la decide el que tiene la IA.
        #expect(report.session(named: "api")?.paneID == "%7")
    }

    @Test("Cada sesión de la sonda tiene el efecto que fija sonda-lectura.json")
    func everySessionHasTheContractEffect() throws {
        let fixtures = ContractFixtures()
        let report = try #require(AgentProbeReport.decode(output: try fixtures.data("agent-tree-v1/sonda-salida.json")))
        let reading = try fixtures.object("agent-tree-v1/sonda-lectura.json")
        let sessions = try #require(reading["sesiones"] as? [[String: Any]], "sonda-lectura.json sin «sesiones»")
        #expect(sessions.count == report.sessions.count)
        for entry in sessions {
            let name = try #require(entry["sesion"] as? String)
            let effect = try #require(entry["efecto"] as? String, "\(name): efecto")
            let session = try #require(report.session(named: name), "\(name) no está en sonda-salida.json")
            #expect(session.effect.rawValue == effect, "\(name)")
            #expect(session.paneID == entry["pane_id"] as? String, "\(name)")
            if let provider = entry["provider"] as? String { #expect(session.agent?.provider == provider, "\(name)") }
            if let id = entry["session_id"] as? String { #expect(session.agent?.sessionID == id, "\(name)") }
            if let cwd = entry["cwd"] as? String { #expect(session.agent?.workingDirectory == cwd, "\(name)") }
            if let asRoot = entry["as_root"] as? Bool { #expect(session.agent?.asRoot == asRoot, "\(name)") }
            if let source = entry["source"] as? String { #expect(session.agent?.source == source, "\(name)") }
        }
    }

    @Test("Las salidas de error y de límite dicen lo mismo que el contrato")
    func errorAndLimitOutputs() throws {
        let reading = try ContractFixtures().object("agent-tree-v1/sonda-lectura.json")
        let outputs = try #require(reading["salidas"] as? [[String: Any]], "sonda-lectura.json sin «salidas»")
        #expect(!outputs.isEmpty)
        for entry in outputs {
            let name = entry["nombre"] as? String ?? "?"
            let output = try #require(entry["salida"], "\(name): salida")
            let data = try JSONSerialization.data(withJSONObject: output)
            let report = try #require(AgentProbeReport.decode(output: data), "\(name)")
            let expected = try #require(entry["espera"] as? [String: Any], "\(name): espera")
            #expect(report.errorCode == expected["error"] as? String, "\(name)")
            #expect(report.missingMeansGone == (expected["ausente_es_desaparecida"] as? Bool), "\(name)")
            if report.error != nil {
                // Con error no se toca nada: ninguna sesión, aunque viniera alguna.
                #expect(report.session(named: "claudebets") == nil, "\(name)")
            }
        }
    }

    @Test("Rechaza cualquier versión que no sea la 1")
    func rejectsOtherVersions() {
        let data = Data(#"{"version":2,"socket":"default","error":null,"sessions":[]}"#.utf8)
        #expect(throws: AgentProbeReport.ReportError.unsupportedVersion(2)) {
            _ = try JSONDecoder().decode(AgentProbeReport.self, from: data)
        }
    }

    @Test("Acepta 256 KiB de JSON más el salto final, y nada más")
    func acceptsTheFinalNewline() throws {
        let head = #"{"version":1,"socket":"default","host":null,"server":false,"error":null,"truncated":false,"sessions":[],"relleno":""#
        let tail = "\"}"
        let padding = String(repeating: "x", count: 256 * 1_024 - head.utf8.count - tail.utf8.count)
        let exact = Data((head + padding + tail).utf8)
        #expect(exact.count == 256 * 1_024)
        #expect(AgentProbeReport.decode(output: exact + Data("\n".utf8)) != nil)
        #expect(AgentProbeReport.decode(output: exact + Data("\n\n".utf8)) == nil)
    }

    @Test("Solo sin_ia de un panel vivo lleva a shell")
    func onlyALiveShellLeadsToShell() {
        let live = AgentProbeReport.Session(
            name: "s", sessionID: "$1", paneID: "%1", reason: "sin_ia", agent: nil,
            panes: [.init(paneID: "%1")]
        )
        let deadPane = AgentProbeReport.Session(
            name: "s", sessionID: "$1", paneID: "%1", reason: "sin_ia", agent: nil,
            panes: [.init(paneID: "%1", isDead: true)]
        )
        let notLive = AgentProbeReport.Session(name: "s", sessionID: nil, paneID: nil, isLive: false, reason: "sin_ia", agent: nil)
        let ambiguous = AgentProbeReport.Session(name: "s", sessionID: "$1", paneID: "%1", reason: "identidad_ambigua", agent: nil)
        #expect(live.effect == .shell)
        #expect(deadPane.effect == .nothing)
        #expect(notLive.effect == .nothing)
        #expect(ambiguous.effect == .nothing)
    }
}
