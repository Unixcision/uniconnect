import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// La IA de una ventana SSH se guarda con lo que la sonda verificó, con historial y sin órdenes.
@Suite("UniConnect: IA de una ventana remota")
struct UniConnectRemoteAgentRecordTests {
    private let first = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
    private let second = "9d4b2e6f-1a3c-4e8b-b7d0-5f2c8a1e6b93"

    private func claude(_ id: String, cwd: String = "/root/xunis") -> UniConnectRemoteAgentRecord.Observation {
        .init(provider: "claude", sessionID: id, workingDirectory: cwd, asRoot: true, source: "ficha")
    }

    @Test("Un id nuevo entra en el historial y pasa a ser la activa")
    func aNewIDBecomesActive() throws {
        var record = try #require(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "default", at: 100))
        let repeated = record.observe(claude(first), at: 160)
        #expect(!repeated)
        let changed = record.observe(claude(second), at: 220)
        #expect(changed)
        #expect(record.sessionID == second)
        #expect(record.runtimeState == .agent)
        #expect(record.history.map(\.sessionID) == [first, second])
    }

    @Test("Volver al shell conserva la última IA")
    func shellKeepsTheLastAgent() throws {
        var record = try #require(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "default", at: 100))
        let toShell = record.observeShell(at: 200)
        #expect(toShell)
        #expect(record.runtimeState == .shell)
        #expect(record.sessionID == first)
        #expect(record.provider == "claude")
        let again = record.observeShell(at: 300)
        #expect(!again)
    }

    @Test("El historial se queda en 32")
    func historyIsBounded() throws {
        var record = try #require(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "default", at: 1))
        for index in 0..<40 {
            _ = record.observe(claude("sesion-\(index)"), at: TimeInterval(10 + index))
        }
        #expect(record.history.count == UniConnectRemoteAgentRecord.maximumHistory)
        #expect(record.history.last?.sessionID == "sesion-39")
    }

    @Test("Un id inválido se rechaza")
    func invalidIDsAreRejected() throws {
        #expect(UniConnectRemoteAgentRecord(observing: claude("a b"), tmuxSocket: "default", at: 1) == nil)
        #expect(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "no valido;", at: 1) == nil)
        var record = try #require(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "default", at: 1))
        let changed = record.observe(claude("$(rm -rf /)"), at: 2)
        #expect(!changed)
        #expect(record.sessionID == first)
        let tampered = Data(#"{"version":1,"provider":"claude","sessionID":"a;b","tmuxSocket":"default","runtimeState":"agent","observedAt":1,"history":[]}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(UniConnectRemoteAgentRecord.self, from: tampered)
        }
    }

    @Test("El panel decodifica un JSON antiguo sin la clave y hace ida y vuelta con ella")
    func panelSnapshotRoundTrip() throws {
        let old = Data(#"{"isRemoteTerminal":true,"uniConnectTmuxSession":"claudebets"}"#.utf8)
        let decodedOld = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: old)
        #expect(decodedOld.uniConnectRemoteAgent == nil)
        #expect(decodedOld.uniConnectTmuxSession == "claudebets")

        let record = try #require(UniConnectRemoteAgentRecord(observing: claude(first), tmuxSocket: "default", at: 1790253004))
        let snapshot = SessionTerminalPanelSnapshot(
            isRemoteTerminal: true,
            uniConnectTmuxSession: "claudebets",
            uniConnectRemoteAgent: record
        )
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(object["uniConnectRemoteAgent"] as? [String: Any])
        #expect(stored["sessionID"] as? String == first)
        #expect(stored["asRoot"] as? Bool == true)
        #expect(stored["runtimeState"] as? String == "agent")
        #expect(stored["resume"] == nil)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.uniConnectRemoteAgent == record)
    }
}
