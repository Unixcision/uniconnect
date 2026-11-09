import Foundation
import Testing
@testable import CMUXAgentLaunch

/// La ficha solo vale si la escribió ESTE proceso: `startedAt` frente a su arranque, ±2 s.
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
}
