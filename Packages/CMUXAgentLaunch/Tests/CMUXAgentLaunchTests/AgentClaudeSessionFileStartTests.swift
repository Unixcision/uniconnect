import Foundation
import Testing
@testable import CMUXAgentLaunch

/// La ficha solo vale si la escribió ESTE proceso: `procStart` frente a su arranque, ±2 s;
/// sin él, `startedAt` entre 2 s antes y 120 s después.
@Suite("Ficha de Claude y arranque del proceso")
struct AgentClaudeSessionFileStartTests {
    private let ficha = #"{"pid":16266,"sessionId":"4eccd582-8862-42d3-b457-0de00ffe49cb","cwd":"/Users/d","startedAt":1794256674006,"procStart":"Mon Nov  9 20:37:53 2026","status":"idle"}"#

    @Test("Coincide con el arranque del proceso dentro de 2 s")
    func matchesItsOwnProcess() throws {
        let file = try JSONDecoder().decode(AgentClaudeSessionFile.self, from: Data(ficha.utf8))
        #expect(file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_256_673.4)))
        #expect(file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_256_675.9)))
    }

    @Test("Una ficha de otro arranque con el PID reutilizado no vale")
    func staleFileFromAReusedPID() throws {
        let file = try JSONDecoder().decode(AgentClaudeSessionFile.self, from: Data(ficha.utf8))
        #expect(!file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_256_680)))
        let old = AgentClaudeSessionFile(sessionId: "x", pid: 16266)
        #expect(!old.matchesProcessStart(Date(timeIntervalSince1970: 1_794_256_674)))
    }

    /// GYM DATOS (11-11-2026): Claude tardó 19,6 s en arrancar por sus servidores MCP, y el Mac la
    /// daba por «identidad ambigua» porque miraba `startedAt` con ±2 s.
    private let lenta = #"{"pid":6461,"sessionId":"4eccd582-8862-42d3-b457-0de00ffe49cb","status":"idle","procStart":"Wed Nov 11 20:41:31 2026","startedAt":1794429711632,"version":"2.1.322"}"#

    @Test("Un arranque lento vale por su procStart, aunque startedAt llegue 20 s después")
    func slowStartMatchesByProcStart() throws {
        let file = try JSONDecoder().decode(AgentClaudeSessionFile.self, from: Data(lenta.utf8))
        #expect(file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_429_691.998)))
        #expect(!file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_429_600)))
        #expect(!file.matchesProcessStart(Date(timeIntervalSince1970: 1_794_429_711.6)))
    }

    @Test("Sin procStart, startedAt vale entre 2 s antes y 120 s después del arranque")
    func startedAtFallbackAllowsASlowStart() {
        let start = Date(timeIntervalSince1970: 1_794_429_691)
        #expect(AgentClaudeSessionFile(sessionId: "x", startedAt: 1_794_429_711_632).matchesProcessStart(start))
        #expect(AgentClaudeSessionFile(sessionId: "x", startedAt: 1_794_429_689_500).matchesProcessStart(start))
        #expect(!AgentClaudeSessionFile(sessionId: "x", startedAt: 1_794_429_685_000).matchesProcessStart(start))
        #expect(!AgentClaudeSessionFile(sessionId: "x", startedAt: 1_794_440_000_000).matchesProcessStart(start))
        // Un procStart que no es una fecha (Linux escribe jiffies) cae en startedAt.
        #expect(AgentClaudeSessionFile(sessionId: "x", procStart: "123456789", startedAt: 1_794_429_711_632).matchesProcessStart(start))
    }
}

