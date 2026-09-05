import CMUXMobileCore
import Foundation

/// A single endpoint-based gate for every RPC, including subscriptions and
/// status probes. The transport supplies the observed peer; JSON never does.
@MainActor
struct UniConnectMobileRequestAuthorizer {
    let access: UniConnectMobileAccessModel

    func authorizationError(for request: MobileHostRPCRequest, observedPeer: TailnetPeerAddress) async -> MobileHostRPCResult? {
        await access.load()
        guard access.isLoaded else { return Self.unavailable }
        guard access.authorize(
            address: observedPeer.rawValue,
            deviceLabel: request.params["device_name"] as? String
        ) else {
            return .failure(MobileHostRPCError(
                code: "approval_required",
                message: String(localized: "uniconnect.mobile.access.approvalRequired", defaultValue: "Autoriza este dispositivo en UniConnect en el equipo al que quieres acceder.")
            ))
        }
        return nil
    }

    static var unavailable: MobileHostRPCResult {
        .failure(MobileHostRPCError(
            code: "access_unavailable",
            message: String(localized: "uniconnect.mobile.access.notReady", defaultValue: "El acceso remoto todavía no está preparado en este equipo.")
        ))
    }
}
