import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Las causas son un catálogo compartido: si un lado añade una y el otro no la conoce, el lector ve
/// un objetivo sin motivo, que se lee como un objetivo olvidado.
@Suite("Catálogo de causas")
struct RelaunchCauseCatalogueTests {
    @Test("Cada causa del contrato tiene su caso aquí")
    func everyCauseInTheContractExists() throws {
        // El fichero que consume el motor Linux. Si añade una causa y esta versión no la tiene, se
        // cae aquí en vez de descubrirse cuando un equipo la mande y el móvil no sepa nombrarla.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/relaunch-v1/causes.json")
        guard let data = try? Data(contentsOf: url) else {
            // El paquete se compila también fuera del repo; sin el fichero no hay nada que comparar.
            return
        }
        let contract = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        let known = Set(RelaunchCause.allCases.map(\.rawValue))
        let missing = Set(contract.keys).subtracting(known)
        #expect(missing.isEmpty, "causas del contrato que este lado no conoce: \(missing.sorted())")
        let extra = known.subtracting(contract.keys)
        #expect(extra.isEmpty, "causas inventadas aquí que el contrato no tiene: \(extra.sorted())")
    }
}
