import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Que el mismo agente no se relance dos veces porque se vea desde dos sitios.
@Suite("Autoridad y duplicados")
struct RelaunchTargetAuthorityTests {
    private func remote(_ pane: String, generation: Int = 1) -> RelaunchTargetKey {
        RelaunchTargetKey(
            destination: .ssh(user: "root", host: "vps.example", port: 22),
            tmuxServer: "uniconnect",
            pane: pane,
            generation: generation
        )
    }

    @Test("La clave es del objetivo, no de quien lo mira")
    func keyIgnoresTheViewer() {
        // El mismo panel remoto, inventariado por el Mac y por el Linux. Si la clave llevara dentro
        // el host que lo ve, serían dos objetivos distintos y cada host lo relanzaría por su cuenta.
        let visto = remote("%2")
        #expect(visto.text == "ssh:root@vps.example:22|tmux:uniconnect|pane:%2|gen:1")
        #expect(visto.paneIdentity == "ssh:root@vps.example:22|tmux:uniconnect|pane:%2")
    }

    @Test("Con dos hosts mirando el mismo panel, solo actúa el dueño")
    func onlyTheOwnerActs() {
        let panel = remote("%2")
        let owners = [panel.paneIdentity: "mac-de-dani"]

        let mac = RelaunchTargetAuthority(hostID: "mac-de-dani").rule(candidates: [panel], owners: owners)
        #expect(mac.map(\.ruling) == [.act])

        let linux = RelaunchTargetAuthority(hostID: "minipc").rule(candidates: [panel], owners: owners)
        #expect(linux.map(\.ruling) == [.defer_(to: "mac-de-dani")])
    }

    @Test("Sin dueño resoluble no se actúa «por si acaso»")
    func withoutAuthorityNothingHappens() {
        // Dos hosts decidiendo cada uno que probablemente les toca a ellos es justo la forma de
        // que se haga dos veces.
        let huerfano = remote("%7")
        let ruling = RelaunchTargetAuthority(hostID: "mac-de-dani")
            .rule(candidates: [huerfano], owners: [:])
        #expect(ruling.map(\.ruling) == [.skip(.noAuthority)])
    }

    @Test("El mismo panel repetido dentro de una petición sigue siendo un panel")
    func duplicatesWithinOneRequestCollapse() {
        let unaVez = remote("%2")
        let otraVez = remote("%2")
        let owners = [unaVez.paneIdentity: "mac-de-dani"]
        let ruling = RelaunchTargetAuthority(hostID: "mac-de-dani")
            .rule(candidates: [unaVez, otraVez], owners: owners)
        #expect(ruling.map(\.ruling) == [.act, .skip(.duplicate)])
    }
}
