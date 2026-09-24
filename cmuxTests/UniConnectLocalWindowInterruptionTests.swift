import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Si el tmux cae con la IA activa y la app abierta, la ventana recuerda qué conversación se
/// interrumpió y al volver a abrirla la reanuda.
@Suite("UniConnect: IA interrumpida en una ventana local")
struct UniConnectLocalWindowInterruptionTests {
    private let claudeID = "714b0eae-b568-4e0c-a70b-c87c0d0a801a"

    private func windowWithActiveClaude() -> UniConnectLocalWindowRecord {
        var record = UniConnectLocalWindowRecord(
            id: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
            visibleName: "MULTIGRAM-CLAUDE",
            boxRoot: "/Users/test/PROYECTOS",
            createdAt: 100,
            updatedAt: 100
        )
        _ = record.record(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeID,
                workingDirectory: "/Users/test/PROYECTOS/MULTIGRAM",
                launchCommand: nil
            ),
            at: 101
        )
        return record
    }

    @Test("Parar con la IA activa la deja como interrumpida")
    func stoppingWithAnActiveAgentInterruptsIt() throws {
        var record = windowWithActiveClaude()
        let active = try #require(record.activeConversationID)
        let stopped = record.markStopped(at: 102)
        #expect(stopped)
        #expect(record.runtimeState == .stopped)
        #expect(record.activeConversationID == nil)
        #expect(record.interruptedConversationID == active)
        #expect(record.latestConversationID == active)
    }

    @Test("Parar un shell no inventa una interrumpida")
    func stoppingAShellInterruptsNothing() {
        var record = windowWithActiveClaude()
        _ = record.transitionToShell(at: 102)
        let stopped = record.markStopped(at: 103)
        #expect(stopped)
        #expect(record.interruptedConversationID == nil)
        let revived = record.reviveInterruptedConversation(at: 104)
        #expect(!revived)
        #expect(record.runtimeState == .stopped)
    }

    @Test("Revivir vuelve a agent con la misma conversación")
    func revivingRestoresTheSameConversation() throws {
        var record = windowWithActiveClaude()
        let active = try #require(record.activeConversationID)
        _ = record.markStopped(at: 102)
        let revived = record.reviveInterruptedConversation(at: 103)
        #expect(revived)
        #expect(record.runtimeState == .agent)
        #expect(record.activeConversationID == active)
        #expect(record.latestConversationID == active)
        #expect(record.interruptedConversationID == nil)
        #expect(record.latestRestorableSnapshot(registry: CmuxVaultAgentRegistry(registrations: []))?.sessionId == claudeID)
        // Una sola vez: ya no queda nada que revivir.
        let revivedAgain = record.reviveInterruptedConversation(at: 104)
        #expect(!revivedAgain)
    }

    @Test("Volver al shell o registrar otra IA limpian la interrumpida")
    func shellAndRecordClearTheInterruption() {
        var toShell = windowWithActiveClaude()
        _ = toShell.markStopped(at: 102)
        let leftToShell = toShell.transitionToShell(at: 103)
        #expect(leftToShell)
        #expect(toShell.interruptedConversationID == nil)

        var recorded = windowWithActiveClaude()
        _ = recorded.markStopped(at: 102)
        _ = recorded.record(
            SessionRestorableAgentSnapshot(kind: .codex, sessionId: "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17",
                                           workingDirectory: "/Users/test/PROYECTOS", launchCommand: nil),
            at: 103
        )
        #expect(recorded.interruptedConversationID == nil)
        #expect(recorded.runtimeState == .agent)
    }

    @Test("Un JSON v4 antiguo sin la clave decodifica igual y el viaje de ida y vuelta la conserva")
    func decodingOldAndNewRecords() throws {
        let old = Data(
            #"{"version":4,"id":"52000000-0000-0000-0000-000000000001","boxRoot":"/repo","workingDirectory":"/repo","runtimeState":"stopped","conversations":[{"id":"52000000-0000-0000-0000-000000000002","kind":"claude","sessionID":"714b0eae-b568-4e0c-a70b-c87c0d0a801a","displayName":"Claude Code","firstSeenAt":1}],"latestConversationID":"52000000-0000-0000-0000-000000000002","createdAt":1,"updatedAt":2}"#.utf8
        )
        let decodedOld = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: old)
        #expect(decodedOld.interruptedConversationID == nil)
        #expect(decodedOld.runtimeState == .stopped)
        let encodedOld = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedOld)) as? [String: Any]
        )
        #expect(encodedOld["interruptedConversationID"] == nil)
        #expect(encodedOld["version"] as? Int == 4)

        var record = windowWithActiveClaude()
        _ = record.markStopped(at: 102)
        let roundTrip = try JSONDecoder().decode(
            UniConnectLocalWindowRecord.self,
            from: JSONEncoder().encode(record)
        )
        #expect(roundTrip == record)
        #expect(roundTrip.interruptedConversationID == record.interruptedConversationID)
    }

    @Test("Una interrumpida que no está en conversations se descarta")
    func anUnknownInterruptionIsDropped() throws {
        let orphan = Data(
            #"{"version":4,"id":"53000000-0000-0000-0000-000000000001","boxRoot":"/repo","runtimeState":"stopped","conversations":[],"interruptedConversationID":"53000000-0000-0000-0000-000000000009","createdAt":1,"updatedAt":2}"#.utf8
        )
        let record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: orphan)
        #expect(record.interruptedConversationID == nil)

        let onShell = Data(
            #"{"version":4,"id":"53000000-0000-0000-0000-000000000002","boxRoot":"/repo","runtimeState":"shell","conversations":[{"id":"53000000-0000-0000-0000-000000000003","kind":"claude","sessionID":"714b0eae-b568-4e0c-a70b-c87c0d0a801a","displayName":"Claude Code","firstSeenAt":1}],"interruptedConversationID":"53000000-0000-0000-0000-000000000003","createdAt":1,"updatedAt":2}"#.utf8
        )
        // Solo una ventana parada puede tener una conversación interrumpida.
        #expect(try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: onShell).interruptedConversationID == nil)
    }
}
