import Foundation
import Testing
@testable import CMUXAgentLaunch

/// La salida de la sonda remota se lee igual en el Mac que en Linux: la fija el contrato.
@Suite("Informe de la sonda remota")
struct AgentProbeReportTests {
    @Test("Decodifica el ejemplo del contrato y agrega por sesión")
    func decodesTheContractExample() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/agent-tree-v1/sonda-salida.json")
        guard let data = try? Data(contentsOf: url) else {
            // El paquete se compila también fuera del repo; sin el fichero no hay nada que comparar.
            return
        }
        let report = try JSONDecoder().decode(AgentProbeReport.self, from: data)
        #expect(report.version == 1)
        #expect(report.error == nil)
        #expect(report.uid == 0)
        #expect(report.socket == "default")
        let claude = try #require(report.session(named: "claudebets"))
        #expect(claude.agent?.provider == "claude")
        #expect(claude.agent?.sessionID == "473ed1de-4397-45ef-b00b-6b17fd7382b0")
        #expect(claude.agent?.asRoot == true)
        #expect(claude.agent?.source == "ficha")
        #expect(claude.sessionID == "$0")
        #expect(claude.paneID == "%0")
        #expect(report.session(named: "scrapper-codex")?.agent?.source == "rollout")
        let noID = try #require(report.session(named: "ufabetbot"))
        #expect(noID.cause == "sin_id")
        #expect(noID.agent?.sessionID == nil)
        #expect(report.session(named: "hgabot")?.cause == "sin_ia")
        #expect(report.session(named: "pruebas")?.cause == "identidad_ambigua")
        // Un panel muerto no se sondea: no dice nada de su sesión.
        #expect(report.session(named: "caida") == nil)
    }

    @Test("Rechaza cualquier versión que no sea la 1")
    func rejectsOtherVersions() {
        let data = Data(#"{"version":2,"socket":"default","error":null,"panes":[]}"#.utf8)
        #expect(throws: AgentProbeReport.ReportError.unsupportedVersion(2)) {
            _ = try JSONDecoder().decode(AgentProbeReport.self, from: data)
        }
    }

    @Test("Con error no se devuelve ninguna sesión")
    func errorsTouchNothing() throws {
        let data = Data(#"{"version":1,"socket":"default","error":"sin_servidor","panes":[]}"#.utf8)
        let report = try JSONDecoder().decode(AgentProbeReport.self, from: data)
        #expect(report.error == "sin_servidor")
        #expect(report.session(named: "x") == nil)
    }

    @Test("IA en dos paneles de la misma sesión es ambigua")
    func twoPanesWithAgentsAreAmbiguous() {
        let agent = AgentProbeReport.Agent(provider: "claude", sessionID: "a", workingDirectory: "/w", asRoot: false, source: "ficha")
        let report = AgentProbeReport(socket: "default", uid: 1000, user: "u", error: nil, panes: [
            .init(session: "s", sessionID: "$1", paneID: "%1", agent: agent, cause: nil),
            .init(session: "s", sessionID: "$1", paneID: "%2", agent: agent, cause: nil),
            .init(session: "s", sessionID: "$1", paneID: "%3", agent: nil, cause: "sin_ia"),
        ])
        #expect(report.session(named: "s")?.cause == "identidad_ambigua")
    }

    @Test("La forma agrupada por sesiones del borrador también se lee")
    func readsTheGroupedDraftShape() throws {
        let data = Data(#"""
        {"version":1,"checked_at":"2026-09-24T14:30:05Z","socket":"default","host":{"hostname":"h","uid":0},
         "server":true,"error":null,"truncated":false,
         "sessions":[{"name":"claudebets","session_id":"$0","pane_id":"%0","pane_pid":41230,"live":true,
                      "reason":null,"agent":{"provider":"claude","session_id":"473ed1de-4397-45ef-b00b-6b17fd7382b0",
                      "cwd":"/root/xunis","as_root":true,"source":"ficha","pid":41251},"panes":[]}]}
        """#.utf8)
        let report = try JSONDecoder().decode(AgentProbeReport.self, from: data)
        #expect(report.uid == 0)
        #expect(report.session(named: "claudebets")?.agent?.workingDirectory == "/root/xunis")
    }
}
