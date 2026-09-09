import Foundation

/// Identidad de la sesión móvil que hace una llamada: la conexión y la dirección del
/// tailnet aprobada. `file_put.v1` liga cada transferencia a ella.
struct MobileHostPeerIdentity: Hashable, Sendable {
    let connectionID: UUID
    /// Dirección numérica del peer aprobado (la que valida `MobileHostService` en cada llamada).
    let address: String

    init(connectionID: UUID, address: String) {
        self.connectionID = connectionID
        self.address = address
    }
}
