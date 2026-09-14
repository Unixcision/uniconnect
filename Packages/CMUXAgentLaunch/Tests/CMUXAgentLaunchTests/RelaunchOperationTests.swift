import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Lo que significa cada campo del resultado, que es donde es fácil mentirle al lector.
@Suite("Resultado de una operación")
struct RelaunchOperationTests {
    private func key(_ pane: String) -> RelaunchTargetKey {
        RelaunchTargetKey(destination: .local(machineID: "mac"), tmuxServer: "uniconnect-local", pane: pane, generation: 1)
    }

    @Test("Una operación recuperada puede seguir a medias")
    func recoveredIsNotFinished() {
        // `recovered` dice que la operación ya existía, no que haya terminado. Confundirlos pone un
        // tic verde al lado de un agente que todavía se está cerrando.
        let operation = RelaunchOperation(
            operationID: UUID(), verb: .agentRelaunch, recovered: true,
            results: [
                .init(key: key("%1"), state: .verified, effectiveID: "conv-1"),
                .init(key: key("%2"), state: .reopening),
            ]
        )
        #expect(operation.recovered)
        #expect(operation.state == .running)
    }

    @Test("Termina cuando ningún objetivo tiene fases por delante")
    func finishesWhenEveryTargetSettled() {
        let operation = RelaunchOperation(
            operationID: UUID(), verb: .agentRelaunch, recovered: false,
            results: [
                .init(key: key("%1"), state: .verified, effectiveID: "conv-1"),
                .init(key: key("%2"), state: .needsUser, cause: .folderTrust),
                .init(key: key("%3"), state: .failed, cause: .hostUnreachable),
            ]
        )
        #expect(operation.state == .finished)
        #expect(operation.needingUser.count == 1)
        // Solo se reintenta lo fallido: lo que espera a una persona no se reintenta solo, y lo
        // verificado no se vuelve a tocar.
        #expect(operation.retryable.map(\.key) == [key("%3")])
    }

    @Test("Cada verbo recorre sus propias fases y verifica lo suyo")
    func eachVerbHasItsOwnPhases() {
        #expect(RelaunchVerb.agentRelaunch.phases == [.planned, .closing, .reopening])
        #expect(RelaunchVerb.transportReconnect.phases == [.planned, .reattaching])
        #expect(RelaunchVerb.agentContinue.phases == [.planned, .delivering])
        // Reconectar no tiene conversación que comparar; continuar compara acuse de recibo.
        #expect(RelaunchVerb.agentRelaunch.verifiesConversationIdentity)
        #expect(!RelaunchVerb.transportReconnect.verifiesConversationIdentity)
        #expect(!RelaunchVerb.agentContinue.verifiesConversationIdentity)
    }
}
