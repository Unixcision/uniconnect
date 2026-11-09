import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Coste de releer la conversación")
struct ClaudeConversationUsageTests {
    private func line(_ usage: [String: Int], sidechain: Bool = false) -> String {
        let object: [String: Any] = ["type": "assistant", "isSidechain": sidechain, "message": ["usage": usage]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("Suma entrada, creación y lectura de caché del último uso, leído desde el final")
    func sumsTheLastUsage() throws {
        let tail = [
            "{\"type\":\"user\"", // línea partida al principio del trozo
            line(["input_tokens": 1, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100, "output_tokens": 5]),
            line(["input_tokens": 2, "cache_creation_input_tokens": 557, "cache_read_input_tokens": 443666, "output_tokens": 547]),
            line(["input_tokens": 9, "cache_read_input_tokens": 9], sidechain: true),
            "{\"type\":\"user\",\"message\":{\"content\":\"hola\"}}",
        ].joined(separator: "\n")
        let usage = try #require(ClaudeConversationUsage(tail: Data(tail.utf8)))
        #expect(usage.contextTokens == 444_225)
    }

    @Test("Sin uso no se inventa un número")
    func noUsageIsUnknown() {
        #expect(ClaudeConversationUsage(tail: Data("{\"type\":\"user\"}\n".utf8)) == nil)
    }

    @Test("La carpeta del proyecto cambia todo lo que no es letra o dígito por un guion")
    func transcriptLocation() {
        let url = ClaudeConversationUsage.transcriptURL(
            configRoot: URL(fileURLWithPath: "/Users/d/.claude"),
            workingDirectory: "/private/tmp/claude-501/-Users-d/x_y.z",
            sessionID: "1c937159-75ef-4c73-a445-ecad5b219db5"
        )
        #expect(url.path == "/Users/d/.claude/projects/-private-tmp-claude-501--Users-d-x-y-z/1c937159-75ef-4c73-a445-ecad5b219db5.jsonl")
    }
}
