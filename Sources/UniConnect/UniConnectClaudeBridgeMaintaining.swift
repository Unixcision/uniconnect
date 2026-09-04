import Foundation

/// Performs explicit, user-authorized cleanup of direct-SSH bridge routes.
protocol UniConnectClaudeBridgeMaintaining: Sendable {
    func removeRemoteIntegration(
        routeIDs: [UUID],
        session: DetectedSSHSession
    ) async throws

    func forgetLocalRoutes(_ routeIDs: [UUID]) async
}
