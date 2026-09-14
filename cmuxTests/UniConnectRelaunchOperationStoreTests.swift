import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Lo que hace que un corte de red no cueste veintiséis agentes cerrados dos veces.
@Suite("Almacén de operaciones de relanzado")
@MainActor
struct UniConnectRelaunchOperationStoreTests {
    private func key(_ pane: String, generation: Int = 1) -> RelaunchTargetKey {
        RelaunchTargetKey(
            destination: .local(machineID: "mac"),
            tmuxServer: "uniconnect-local",
            pane: pane,
            generation: generation
        )
    }

    private func target(_ pane: String) -> UniConnectRelaunchExecutor.Target {
        .init(
            key: key(pane), label: "caja · \(pane)", provider: "claude",
            socket: "uniconnect-local", session: pane, previousArgv: ["claude"]
        )
    }

    @Test("Una operación aceptada se reconoce antes de terminar")
    func acceptedBeforeFinishing() {
        // Escrita ANTES de cerrar nada a propósito: una operación que solo existe cuando termina es
        // una operación que un corte de red borra, y borrarla es lo que hace que el reintento cierre
        // todo por segunda vez.
        let store = UniConnectRelaunchOperationStore()
        let token = store.issue(deviceID: "movil", verb: .agentRelaunch, targets: [target("%1"), target("%2")])
        #expect(store.accepted.isEmpty, "antes de aceptar no hay nada que recuperar")

        store.accept(operationID: token.operationID, verb: .agentRelaunch, targets: [key("%1"), key("%2")])
        #expect(store.accepted[token.operationID]?.deviceID == "movil")

        let operation = store.operation(token.operationID, recovered: false)
        #expect(operation?.state == .running, "aceptada no es terminada")
        #expect(operation?.results.allSatisfy { $0.state == .planned } == true)
    }

    @Test("Recuperarla la marca como recuperada sin cambiar lo que paso")
    func recoveryMarksButDoesNotAlter() {
        let store = UniConnectRelaunchOperationStore()
        let token = store.issue(deviceID: "movil", verb: .agentRelaunch, targets: [target("%1")])
        store.accept(operationID: token.operationID, verb: .agentRelaunch, targets: [key("%1")])
        store.update(operationID: token.operationID, results: [
            .init(key: key("%1"), state: .verified, effectiveID: "conv-1"),
        ])

        let recovered = store.operation(token.operationID, recovered: true)
        #expect(recovered?.recovered == true)
        // `recovered` dice que ya existía; `state` dice si terminó. Son dos preguntas distintas.
        #expect(recovered?.state == .finished)
        #expect(recovered?.results.first?.effectiveID == "conv-1")
    }

    @Test("El vale se ata al dispositivo, al verbo y a los objetivos con su generación")
    func theTokenBindsEverythingThatMatters() {
        let store = UniConnectRelaunchOperationStore()
        let token = store.issue(deviceID: "movil", verb: .agentRelaunch, targets: [target("%1")])
        #expect(token.belongs(to: "movil", verb: .agentRelaunch))
        #expect(!token.belongs(to: "otro-movil", verb: .agentRelaunch))
        #expect(token.targets == [key("%1")])
    }

    @Test("El vale caduca, y la caducidad no borra lo que ya se acepto")
    func expiryDoesNotEraseAnAcceptedOperation() {
        let store = UniConnectRelaunchOperationStore(clock: { Date(timeIntervalSince1970: 0) })
        let token = store.issue(deviceID: "movil", verb: .agentRelaunch, targets: [target("%1")], lifetime: 10)
        store.accept(operationID: token.operationID, verb: .agentRelaunch, targets: [key("%1")])

        let muchoDespues = Date(timeIntervalSince1970: 10_000)
        #expect(token.hasExpired(at: muchoDespues))
        // Aun caducado, la operación sigue ahí para consultarla: exigir un plan nuevo aquí
        // convertiría el corte de red en trabajo perdido.
        #expect(store.operation(token.operationID, recovered: true) != nil)
        #expect(store.accepted[token.operationID] != nil)
    }

    @Test("Una operación que nunca se aceptó no se puede recuperar")
    func nothingToRecoverWithoutAcceptance() {
        let store = UniConnectRelaunchOperationStore()
        let token = store.issue(deviceID: "movil", verb: .agentRelaunch, targets: [target("%1")])
        #expect(store.operation(token.operationID, recovered: true) == nil)
        #expect(store.targets(for: token.operationID).count == 1, "pero su plan sigue recordado")
    }
}
