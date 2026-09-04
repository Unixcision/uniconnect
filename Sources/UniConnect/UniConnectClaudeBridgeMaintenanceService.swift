import CryptoKit
import Foundation
import UniConnectClaudeBridge

/// Owns bridge cleanup commands and encrypted-token removal outside UI state.
actor UniConnectClaudeBridgeMaintenanceService: UniConnectClaudeBridgeMaintaining {
    enum MaintenanceError: Error {
        case invalidSSHInvocation
    }

    private let tokenStore: any ClaudeBridgeTokenStoring
    private let commandExecutor: any UniConnectSSHCommandExecuting
    private let installationID: String

    init(
        tokenStore: any ClaudeBridgeTokenStoring,
        commandExecutor: any UniConnectSSHCommandExecuting,
        installationKey: SymmetricKey
    ) {
        self.tokenStore = tokenStore
        self.commandExecutor = commandExecutor
        let keyData = installationKey.withUnsafeBytes { Data($0) }
        self.installationID = ClaudeBridgeInstallationIdentity.derive(from: keyData)
    }

    func removeRemoteIntegration(
        routeIDs: [UUID],
        session: DetectedSSHSession
    ) async throws {
        let uniqueRouteIDs = Array(Set(routeIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueRouteIDs.isEmpty else { return }
        let remoteCommand = ClaudeBridgeRemoteIntegration.remoteCleanupCommand(
            routeIDs: uniqueRouteIDs,
            installationID: installationID
        )
        guard let invocation = UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: remoteCommand
        ) else {
            throw MaintenanceError.invalidSSHInvocation
        }
        try await commandExecutor.execute(invocation, timeout: .seconds(20))
        for routeID in uniqueRouteIDs {
            try await tokenStore.removeToken(for: routeID)
        }
    }

    func forgetLocalRoutes(_ routeIDs: [UUID]) async {
        for routeID in Set(routeIDs) {
            try? await tokenStore.removeToken(for: routeID)
        }
    }
}
