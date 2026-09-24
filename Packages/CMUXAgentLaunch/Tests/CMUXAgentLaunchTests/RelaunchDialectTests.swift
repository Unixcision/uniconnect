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
        // Codex (D7, 24-09) está escrito pero fuera de los anunciados hasta probarlo en vivo: relanzar
        // cierra la IA. Su adaptador sí confirma `/exit` en el compositor y espera a que muera.
        #expect(dialects.dialect(for: "codex") == nil)
        #expect(CodexRelaunchDialect().closing == .confirmedCommand("/exit"))
        #expect(dialects.dialect(for: "claude")?.closing == .sequenced)
        #expect(dialects.dialect(for: "grok") == nil)
        #expect(dialects.dialect(for: "agy") == nil)
    }

    @Test("Lo que anuncia el Mac es exactamente su fila de proveedores.json")
    func macCapabilitiesMatchTheContract() throws {
        let contract = try ContractFixtures().object("relaunch-v1/proveedores.json")
        let capabilities = try #require(contract["capacidades"] as? [String: [String]], "proveedores.json sin «capacidades»")
        let mac = try #require(capabilities["macos"], "proveedores.json sin fila macos")
        let announced = ["relaunch.v1"] + RelaunchDialects.known.capabilityTokens(windowKind: "local")
        #expect(announced.sorted() == mac.sorted())
    }

    @Test("Claude vuelve con su conversación y sus banderas, como argumentos y no como frase")
    func claudeComesBackAsItWas() {
        let claude = ClaudeRelaunchDialect()
        #expect(claude.invocation(
            conversation: "eba669f0-e4cb-4e15-8661-fab7ff1b022e",
            previousArgv: ["claude", "--resume", "otra", "--dangerously-skip-permissions"]
        ) == ["claude", "--resume", "eba669f0-e4cb-4e15-8661-fab7ff1b022e", "--dangerously-skip-permissions"])

        // Desde el 24-09 (decisión de Dani) relanzar va siempre sin preguntas: sin esa bandera
        // antes, se añade igual, una vez y al final.
        #expect(claude.invocation(conversation: "abc", previousArgv: ["claude"])
            == ["claude", "--resume", "abc", "--dangerously-skip-permissions"])
    }
}

/// Codex se cierra como en Linux (`exit_codex`) y vuelve con `--yolo` y `supersedes` aplicado.
@Suite("Adaptador de Codex")
struct CodexRelaunchDialectTests {
    private let id = "019a4e2b-6c3d-7f81-9a05-3e7b1c8d2f46"

    @Test("Vuelve con --yolo, su conversación y las opciones que se pueden devolver tal cual")
    func invocationKeepsReproducibleOptions() {
        let codex = CodexRelaunchDialect()
        #expect(codex.invocation(conversation: id, previousArgv: ["node", "/usr/local/bin/codex", "--yolo"])
            == ["codex", "--yolo", "resume", id])
        #expect(codex.invocation(
            conversation: id,
            previousArgv: ["codex", "resume", "0199f3c2-8d1e-7b40-a6f5-2c9e4d7b1a08", "-a", "on-request",
                           "--sandbox", "workspace-write", "--full-auto", "-m", "gpt-5-codex", "-C", "/home/u/api"]
        ) == ["codex", "--yolo", "resume", id, "-m", "gpt-5-codex", "-C", "/home/u/api"])
        #expect(codex.invocation(conversation: id, previousArgv: [])
            == ["codex", "--yolo", "resume", id])
    }

    @Test("Lo que no se puede devolver tal cual se niega, antes de cerrar nada")
    func irreproducibleOptionsAreRefused() {
        let codex = CodexRelaunchDialect()
        // Un mensaje inicial, una opción desconocida o un valor con comillas que `ps` pudo partir.
        #expect(codex.invocation(conversation: id, previousArgv: ["codex", "--yolo", "arregla", "los", "tests"]) == nil)
        #expect(codex.invocation(conversation: id, previousArgv: ["codex", "--image", "a.png"]) == nil)
        #expect(codex.invocation(conversation: id, previousArgv: ["codex", "-c", "effort=\"high\""]) == nil)
        #expect(codex.invocation(conversation: id, previousArgv: ["codex", "exec", "hola"]) == nil)
        #expect(codex.invocation(conversation: "no válido", previousArgv: ["codex"]) == nil)
        // Sin política no se sabe quitar lo que --yolo sustituye.
        #expect(CodexRelaunchDialect(policy: nil).invocation(conversation: id, previousArgv: ["codex"]) == nil)
    }

    @Test("Solo se cierra con el compositor vacío; una pregunta es de una persona")
    func closesOnlyAnEmptyComposer() {
        let codex = CodexRelaunchDialect()
        let empty = RelaunchPaneScreen(text: "Codex\n\n›\n  ⏎ send", cursorRow: 2, cursorColumn: 2)
        #expect(codex.refusalToClose(screen: empty) == nil)
        let draft = RelaunchPaneScreen(text: "Codex\n\n› arregla esto\n", cursorRow: 2, cursorColumn: 14)
        #expect(codex.refusalToClose(screen: draft) == .unknownDialog)
        let placeholder = RelaunchPaneScreen(
            text: "Codex\n› Ask Codex to do anything\n", cursorRow: 1, cursorColumn: 2,
            styledText: "Codex\n\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n"
        )
        #expect(codex.refusalToClose(screen: placeholder) == nil)
        // Las mismas palabras escritas por alguien (sin atenuar) son un borrador.
        let typed = RelaunchPaneScreen(
            text: "Codex\n› Ask Codex to do anything\n", cursorRow: 1, cursorColumn: 2,
            styledText: "Codex\n›  Ask Codex to do anything\n"
        )
        #expect(codex.refusalToClose(screen: typed) == .unknownDialog)
        let question = RelaunchPaneScreen(text: "Allow once?\n›\n", cursorRow: 1, cursorColumn: 2)
        #expect(codex.refusalToClose(screen: question) == .permissions)
    }

    @Test("Intro solo cuando «› /exit» está en la línea del cursor")
    func enterOnlyWhenTheCommandIsShown() {
        let codex = CodexRelaunchDialect()
        #expect(codex.showsCloseCommand(screen: .init(text: "x\n› /exit  \n", cursorRow: 1, cursorColumn: 7)))
        #expect(!codex.showsCloseCommand(screen: .init(text: "x\n› /exi\n", cursorRow: 1, cursorColumn: 6)))
        #expect(!codex.showsCloseCommand(screen: .init(text: "› /exit\n›\n", cursorRow: 1, cursorColumn: 2)))
    }

    @Test("La conversación del proceso nuevo sale de su `resume <id>`")
    func resumesReadsTheSubcommand() {
        let codex = CodexRelaunchDialect()
        #expect(codex.resumes(conversation: id, argv: ["node", "/usr/local/bin/codex", "--yolo", "resume", id]))
        #expect(!codex.resumes(conversation: id, argv: ["codex", "--yolo", "--", "resume", id]))
        #expect(!codex.resumes(conversation: id, argv: ["codex", "--yolo"]))
        #expect(ClaudeRelaunchDialect().resumes(conversation: id, argv: ["claude", "--resume", id]))
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
