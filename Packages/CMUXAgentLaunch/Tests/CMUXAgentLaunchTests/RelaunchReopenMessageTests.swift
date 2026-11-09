import Foundation
import Testing
@testable import CMUXAgentLaunch

/// El mensaje gasta cupo: solo se escribe con monitores o si estaba trabajando, y su texto es el de
/// `mensajes.json`, el mismo en Mac y Linux.
@Suite("Mensaje tras reabrir")
struct RelaunchReopenMessageTests {
    @Test("Los textos son los del contrato, letra a letra")
    func textsAreTheContracts() throws {
        let contract = try ContractFixtures().object("relaunch-v1/mensajes.json")
        #expect(contract["motivo_actualizar"] as? String == RelaunchReopenMessage.updateReason)
        #expect(contract["motivo_relanzar"] as? String == RelaunchReopenMessage.relaunchReason)
        #expect(contract["con_monitores"] as? String == RelaunchReopenMessage.withMonitors)
        #expect(contract["solo_cortado"] as? String == RelaunchReopenMessage.onlyInterrupted)
        #expect(contract["anadido_cortado"] as? String == RelaunchReopenMessage.interruptedSuffix)
    }

    @Test("Ocioso y sin monitores no recibe nada")
    func idleWithoutMonitorsGetsNothing() {
        #expect(RelaunchReopenMessage(reason: .relaunch, monitors: 0, monitorsFile: nil, wasWorking: false) == nil)
        #expect(!RelaunchReopenMessage.isNeeded(monitors: 0, wasWorking: false))
    }

    @Test("Con monitores dice cuántos y dónde están, y el motivo de la actualización")
    func monitorsNameCountFileAndVersion() throws {
        let message = try #require(RelaunchReopenMessage(
            reason: .update(version: "2.1.321"), monitors: 3, monitorsFile: "/x/m.txt", wasWorking: false
        ))
        #expect(message.text.hasPrefix("UniConnect te ha reiniciado para actualizar Claude Code a 2.1.321. Al cerrar se pararon tus 3 monitores"))
        #expect(message.text.contains("guardados tal cual en /x/m.txt."))
        #expect(!message.text.contains("{"))
    }

    @Test("Trabajando con monitores añade que se cortó; trabajando sin ellos, solo eso")
    func workingAddsTheInterruption() throws {
        let both = try #require(RelaunchReopenMessage(reason: .relaunch, monitors: 1, monitorsFile: "/m", wasWorking: true))
        #expect(both.text.hasSuffix(RelaunchReopenMessage.interruptedSuffix))
        let only = try #require(RelaunchReopenMessage(reason: .relaunch, monitors: 0, monitorsFile: nil, wasWorking: true))
        #expect(only.text == "UniConnect te ha reiniciado para relanzarte mientras trabajabas, así que lo que tenías en marcha se cortó a medias. Retómalo justo donde se quedó.")
    }
}
