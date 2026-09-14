import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Cualquier IA conectada, no solo Claude: cada una con su dialecto, y la que no tenga, intacta.
@Suite("Dialectos por agente")
struct RelaunchDialectTests {
    @Test("Un agente sin dialecto no se toca; se dice que no se sabe hablarle")
    func anUnknownAgentIsRefusedNotGuessed() {
        // Callar y «probar algo» con un agente desconocido es como se estropea una conversación
        // ajena. Se informa y se deja exactamente como estaba.
        let dialects = RelaunchDialects.known
        #expect(dialects.dialect(for: "claude") != nil)
        #expect(dialects.dialect(for: "codex") == nil)
        #expect(dialects.dialect(for: "gemini") == nil)
    }

    @Test("El proveedor se reconoce sin importar mayúsculas")
    func providerLookupIgnoresCase() {
        #expect(RelaunchDialects.known.dialect(for: "CLAUDE")?.provider == "claude")
    }

    @Test("Claude vuelve con su conversación y con las banderas que tenía")
    func claudeComesBackAsItWas() {
        let claude = ClaudeRelaunchDialect()
        #expect(claude.relaunchCommand(
            sessionID: "eba669f0-e4cb-4e15-8661-fab7ff1b022e",
            previousArguments: ["claude", "--resume", "otra", "--dangerously-skip-permissions"]
        ) == "claude --resume eba669f0-e4cb-4e15-8661-fab7ff1b022e --dangerously-skip-permissions")

        // Sin esa bandera antes, no se añade: relanzar no es el momento de cambiar lo que a un
        // agente se le permite hacer.
        #expect(claude.relaunchCommand(sessionID: "abc", previousArguments: ["claude"])
            == "claude --resume abc")
    }

    @Test("Sin conversación que nombrar, Claude no se relanza")
    func withoutAConversationItRefuses() {
        // `--continue` cogería la última sesión tocada en esa carpeta, y varias ventanas comparten
        // carpeta: reanudar la conversación equivocada es peor que no reanudar.
        #expect(ClaudeRelaunchDialect().relaunchCommand(sessionID: nil, previousArguments: ["claude"]) == nil)
        #expect(ClaudeRelaunchDialect().relaunchCommand(sessionID: "", previousArguments: ["claude"]) == nil)
    }
}
