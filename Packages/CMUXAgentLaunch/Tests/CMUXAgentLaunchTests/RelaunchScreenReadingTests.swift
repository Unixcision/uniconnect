import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Leer la pantalla antes de teclear. Cada caso aquí rompió algo al hacerlo a mano.
@Suite("Lectura de pantalla")
struct RelaunchScreenReadingTests {
    @Test("Un agente en su prompt se reconoce por el pie")
    func readsAReadyAgent() {
        let screen = """
          danielgomezmartin@MacBook-Pro-de-Daniel:~/Desktop/IMPUESTOS | Opus 5 | effort:high
          ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent
        """
        #expect(RelaunchScreenReading.read(screen: screen) == .agentReady)
    }

    @Test("La opción de salir se busca por su texto, nunca por su posición")
    func findsTheExitOptionByItsWording() {
        // Si el orden cambia entre versiones, elegir «la primera» acepta lo que toque.
        let primera = """
          Background work is running
          The following will stop when you exit:
          monitor · entradas nuevas
          ❯ 1. Exit and stop tasks
            2. Move to background and exit
            3. Stay
        """
        #expect(RelaunchScreenReading.read(screen: primera) == .backgroundWorkQuestion(exitOption: 1))

        let movida = """
          Background work is running
          ❯ 1. Move to background and exit
            2. Exit and stop tasks
            3. Stay
        """
        #expect(RelaunchScreenReading.read(screen: movida) == .backgroundWorkQuestion(exitOption: 2))
    }

    @Test("Un diálogo de trabajo en segundo plano sin la opción esperada no se contesta")
    func refusesAnUnfamiliarVersionOfTheQuestion() {
        let raro = """
          Background work is running
          ❯ 1. Algo que no conozco
            2. Otra cosa
        """
        #expect(RelaunchScreenReading.read(screen: raro) == .unrecognised)
    }

    @Test("La confianza de carpeta se reconoce y se deja intacta")
    func recognisesTheFolderTrustQuestion() {
        // Llega con «No, exit» preseleccionado: contestar a ciegas mata la sesión recién abierta.
        let screen = """
          Do you trust the files in this folder?
          ❯ No, exit
            Yes, I trust this folder
        """
        #expect(RelaunchScreenReading.read(screen: screen) == .folderTrustQuestion)
    }

    @Test("Al salir, el agente dice con qué id se retoma")
    func picksUpTheResumeIdentifier() {
        let screen = """
          Resume this session with:
          claude --resume eba669f0-e4cb-4e15-8661-fab7ff1b022e
          danielgomezmartin@MacBook-Pro-de-Daniel IMPUESTOS %
        """
        #expect(RelaunchScreenReading.read(screen: screen)
            == .exitedShowingResume(sessionID: "eba669f0-e4cb-4e15-8661-fab7ff1b022e"))
    }

    @Test("Una pantalla que no se reconoce no recibe teclas")
    func unknownScreensGetNothing() {
        let lista = """
          ∙ repo status check          Estado del repo notbetting-app
          ❯ describe a task for a new session
            enter to return · space to reply
        """
        #expect(RelaunchScreenReading.read(screen: lista) == .unrecognised)
    }
}

/// Qué se hace con cada lectura.
@Suite("Secuencia de un panel")
struct RelaunchPaneSequencerTests {
    private let sequencer = RelaunchPaneSequencer()

    @Test("Cerrar: se escribe /exit, y el diálogo se contesta con el número que toca")
    func closingWalksTheRightPath() {
        #expect(sequencer.stepToClose(reading: .agentReady) == .type("/exit"))
        // Con tareas o monitores en marcha no se cierra: se cancela la pregunta y decide una persona.
        #expect(sequencer.stepToClose(reading: .backgroundWorkQuestion(exitOption: 2)) == .cancelAndStop(.backgroundTasks))
        #expect(sequencer.stepToClose(reading: .shellPrompt) == .done)
    }

    @Test("Cerrar: ante lo desconocido o un permiso, se para y se dice")
    func closingStopsInsteadOfGuessing() {
        #expect(sequencer.stepToClose(reading: .unrecognised) == .stop(.unknownDialog))
        #expect(sequencer.stepToClose(reading: .folderTrustQuestion) == .stop(.folderTrust))
    }

    @Test("Reabrir: se lanza el comando y se para si piden confianza de carpeta")
    func reopeningNeverAnswersAPermission() {
        let orden = "claude --resume abc --dangerously-skip-permissions"
        #expect(sequencer.stepToReopen(reading: .shellPrompt, command: orden) == .type(orden))
        #expect(sequencer.stepToReopen(reading: .agentReady, command: orden) == .done)
        #expect(sequencer.stepToReopen(reading: .folderTrustQuestion, command: orden) == .stop(.folderTrust))
        #expect(sequencer.stepToReopen(reading: .unrecognised, command: orden) == .stop(.unknownDialog))
    }
}
