import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `contracts/ssh-server-return-v1/casos.json`: la misma secuencia de comprobaciones decide lo
/// mismo en el Mac que en Linux.
@Suite("UniConnect: rearmar la reconexión SSH al volver el servidor (contrato)")
struct UniConnectSSHServerReturnContractTests {
    struct Case: Decodable {
        let nombre: String
        let observaciones: [Bool]
        let decisiones: [String]
    }

    struct Contract: Decodable {
        let contrato: String
        let casos: [Case]
    }

    static func contract(from testFile: String = #filePath) throws -> Contract {
        var components = URL(fileURLWithPath: testFile).deletingLastPathComponent().pathComponents
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components + ["contracts", "ssh-server-return-v1", "casos.json"])
            if FileManager.default.fileExists(atPath: candidate) {
                return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: URL(fileURLWithPath: candidate)))
            }
            components.removeLast()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("Cada caso del contrato decide lo mismo, comprobación a comprobación")
    func everyCaseMatches() throws {
        let contract = try Self.contract()
        #expect(contract.contrato == "ssh-server-return.v1")
        #expect(!contract.casos.isEmpty)
        for item in contract.casos {
            var policy = UniConnectSSHServerReturnPolicy()
            let decided = item.observaciones.map { policy.observe(serverAnswers: $0).rawValue }
            #expect(decided == item.decisiones, "\(item.nombre)")
        }
    }
}

/// El vigilante: una comprobación por servidor y ronda, el estado de cada ventana sobrevive entre
/// esperas y una ventana que ya no importa deja de vigilarse.
@MainActor
@Suite("UniConnect: vigilante de servidores SSH caídos")
struct UniConnectSSHServerWaiterTests {
    actor ScriptedProbe: UniConnectSSHEndpointProbing {
        private var answers: [Bool]
        private(set) var calls: [String] = []

        init(_ answers: [Bool]) {
            self.answers = answers
        }

        func answers(host: String, port: Int) async -> Bool {
            calls.append("\(host):\(port)")
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    final class Counter {
        var value = 0
    }

    func key(_ session: String, host: String = "100.123.234.20") throws -> UniConnectSSHTargetKey {
        try #require(UniConnectSSHTargetKey(destination: "dgomezm@\(host)", port: 22, tmuxSession: session))
    }

    @Test("Servidor caído que vuelve: espera y rearma una sola vez")
    func serverThatComesBackRearms() async throws {
        let probe = ScriptedProbe([false, false, true])
        let waiter = UniConnectSSHServerWaiter(probe: probe, startsAutomatically: false)
        let rearms = Counter()
        let minipc = try key("MTPROTO")
        waiter.wait(for: minipc, isRelevant: { true }, onReturn: { rearms.value += 1 })

        await waiter.checkWaitingServers()
        await waiter.checkWaitingServers()
        #expect(rearms.value == 0)
        #expect(waiter.waitingKeys == [minipc])
        await waiter.checkWaitingServers()
        #expect(rearms.value == 1)
        #expect(waiter.waitingKeys.isEmpty)
    }

    @Test("Varias ventanas del mismo servidor gastan una sola comprobación por ronda")
    func oneProbePerServerPerRound() async throws {
        let probe = ScriptedProbe([false, true])
        let waiter = UniConnectSSHServerWaiter(probe: probe, startsAutomatically: false)
        let rearms = Counter()
        for window in ["MTPROTO", "XUNIS-CLAUSUBOT", "ANASTASIIA", "PANENKA-SCRAPE"] {
            waiter.wait(for: try key(window), isRelevant: { true }, onReturn: { rearms.value += 1 })
        }
        await waiter.checkWaitingServers()
        #expect(await probe.calls.count == 1)
        await waiter.checkWaitingServers()
        #expect(await probe.calls.count == 2)
        #expect(rearms.value == 4)
    }

    @Test("Si el servidor contesta pero no engancha, un solo intento extra aunque se vuelva a esperar")
    func answeringServerGetsOneExtraAttemptAcrossWaits() async throws {
        let probe = ScriptedProbe([true, true])
        let waiter = UniConnectSSHServerWaiter(probe: probe, startsAutomatically: false)
        let rearms = Counter()
        let window = try key("PANENKA-SCRAPE")
        waiter.wait(for: window, isRelevant: { true }, onReturn: { rearms.value += 1 })
        await waiter.checkWaitingServers()
        #expect(rearms.value == 1)

        // El intento extra también se agota: la ventana vuelve a esperar con la misma política.
        waiter.wait(for: window, isRelevant: { true }, onReturn: { rearms.value += 1 })
        await waiter.checkWaitingServers()
        #expect(rearms.value == 1)
        #expect(waiter.waitingKeys.isEmpty)
    }

    @Test("Olvidar una ventana (estable o reconectada a mano) le devuelve su intento extra")
    func forgetResetsThePolicy() async throws {
        let probe = ScriptedProbe([true, true])
        let waiter = UniConnectSSHServerWaiter(probe: probe, startsAutomatically: false)
        let rearms = Counter()
        let window = try key("ANASTASIIA")
        waiter.wait(for: window, isRelevant: { true }, onReturn: { rearms.value += 1 })
        await waiter.checkWaitingServers()
        waiter.forget(window)
        waiter.wait(for: window, isRelevant: { true }, onReturn: { rearms.value += 1 })
        await waiter.checkWaitingServers()
        #expect(rearms.value == 2)
    }

    @Test("Una ventana cerrada o ya conectada deja de vigilarse sin gastar comprobaciones")
    func irrelevantWindowIsDropped() async throws {
        let probe = ScriptedProbe([true])
        let waiter = UniConnectSSHServerWaiter(probe: probe, startsAutomatically: false)
        let rearms = Counter()
        waiter.wait(for: try key("MTPROTO"), isRelevant: { false }, onReturn: { rearms.value += 1 })
        await waiter.checkWaitingServers()
        #expect(rearms.value == 0)
        #expect(await probe.calls.isEmpty)
        #expect(waiter.waitingKeys.isEmpty)
    }
}
