import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Cualquier IA conectada, no solo Claude. Y saber cómo se escribe una no es saber cómo vive.
@Suite("Adaptadores por agente")
struct RelaunchDialectTests {
    @Test("Un agente sin adaptador no se toca; se dice que no se sabe hablarle")
    func anUnknownAgentIsRefusedNotGuessed() {
        let dialects = RelaunchDialects.known
        #expect(dialects.dialect(for: "claude") != nil)
        // Codex tiene documentado `/exit` y `codex resume <id>`, y aun asi no basta: la sintaxis no
        // acredita el ciclo de vida, ni la identidad, ni que haya un proceso nuevo detras.
        #expect(dialects.dialect(for: "codex") == nil)
        #expect(dialects.dialect(for: "grok") == nil)
    }

    @Test("Claude vuelve con su conversación y sus banderas, como argumentos y no como frase")
    func claudeComesBackAsItWas() {
        let claude = ClaudeRelaunchDialect()
        #expect(claude.invocation(
            conversation: "eba669f0-e4cb-4e15-8661-fab7ff1b022e",
            previousArgv: ["claude", "--resume", "otra", "--dangerously-skip-permissions"]
        ) == ["claude", "--resume", "eba669f0-e4cb-4e15-8661-fab7ff1b022e", "--dangerously-skip-permissions"])

        // Sin esa bandera antes, no se añade.
        #expect(claude.invocation(conversation: "abc", previousArgv: ["claude"]) == ["claude", "--resume", "abc"])
    }
}

/// La identidad sale de fuera de la pantalla, y solo cuando la prueba es de verdad.
@Suite("Evidencia de identidad")
struct RelaunchIdentityEvidenceTests {
    @Test("Un cerrojo que el proceso vivo retiene prueba la conversación")
    func aHeldLockProves() {
        let evidence = RelaunchIdentityEvidence(
            processID: 4242, pane: "%13", lockedConversations: ["conv-a"]
        )
        #expect(evidence.provenConversation == "conv-a")
    }

    @Test("Dos candidatas no son una: ambiguo se rechaza, no se sortea")
    func twoCandidatesAreAmbiguous() {
        let evidence = RelaunchIdentityEvidence(
            processID: 4242, pane: "%13",
            lockedConversations: ["conv-a"], writableRollouts: ["conv-b"]
        )
        #expect(evidence.provenConversation == nil)
    }

    @Test("Un hook solo vale si su proceso y su panel son estos")
    func aHookMustMatchTheProcessAndPane() {
        let bueno = RelaunchIdentityEvidence(
            processID: 4242, pane: "%13",
            hook: .init(conversationID: "conv-a", processID: 4242, pane: "%13")
        )
        #expect(bueno.provenConversation == "conv-a")

        // Un hook de otro proceso es de otra conversación por mucho que esté ahí el fichero.
        let otroProceso = RelaunchIdentityEvidence(
            processID: 4242, pane: "%13",
            hook: .init(conversationID: "conv-a", processID: 99, pane: "%13")
        )
        #expect(otroProceso.provenConversation == nil)

        let otroPanel = RelaunchIdentityEvidence(
            processID: 4242, pane: "%13",
            hook: .init(conversationID: "conv-a", processID: 4242, pane: "%2")
        )
        #expect(otroPanel.provenConversation == nil)
    }

    @Test("Sin nada retenido no hay conversación probada")
    func nothingHeldProvesNothing() {
        #expect(RelaunchIdentityEvidence(processID: 4242, pane: "%13").provenConversation == nil)
    }
}

/// Que el agente haya vuelto de verdad, no que el panel lo parezca.
@Suite("Prueba de proceso nuevo")
struct RelaunchProcessProofTests {
    @Test("El mismo proceso de antes no prueba nada")
    func sameProcessIsNotARelaunch() {
        // Un panel puede tener el mismo aspecto porque no ha pasado nada en absoluto.
        let proof = RelaunchProcessProof(before: 100, after: 100)
        #expect(!proof.provesNewProcess)
        #expect(proof.failureCause == .ambiguousIdentity)
    }

    @Test("Un proceso distinto y el agente en su prompt sí")
    func aNewProcessAtItsPromptPasses() {
        let proof = RelaunchProcessProof(before: 100, after: 101)
        #expect(proof.provesNewProcess)
        let verdict = ClaudeRelaunchDialect().verify(proof: proof, reading: .agentReady)
        #expect(verdict.isSuccess)
    }

    @Test("Proceso nuevo pero pantalla rara no se da por bueno")
    func aNewProcessOnAnOddScreenIsNotVerified() {
        let verdict = ClaudeRelaunchDialect()
            .verify(proof: .init(before: 100, after: 101), reading: .unrecognised)
        #expect(verdict.failureCause == .unknownDialog)
    }

    @Test("Sin proceso detrás, tampoco")
    func noProcessAtAllFails() {
        #expect(!RelaunchProcessProof(before: 100, after: nil).provesNewProcess)
    }
}

private extension Result where Success == Void, Failure == RelaunchCause {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var failureCause: RelaunchCause? { if case let .failure(cause) = self { cause } else { nil } }
}
