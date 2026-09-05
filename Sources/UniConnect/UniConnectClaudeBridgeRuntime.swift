import CryptoKit
import Foundation
import Observation
import UniConnectClaudeBridge

/// Main-actor bridge coordinator assembled by the executable composition root.
@MainActor
@Observable
final class UniConnectClaudeBridgeRuntime {
    private struct RouteEnvelope: Decodable {
        let routeID: UUID

        enum CodingKeys: String, CodingKey {
            case routeID = "route_id"
        }
    }

    private let listener: ClaudeBridgeLoopbackListener
    private nonisolated let service: ClaudeBridgeService
    private let installationID: String
    private let statusDelivery: @MainActor @Sendable (ClaudeBridgeRoute, ClaudeBridgeStatus) -> Void
    nonisolated let sessionSignals: AsyncStream<ClaudeBridgeSessionSignal>
    private var statusTask: Task<Void, Never>?
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var routeRebindTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var statuses: [UUID: ClaudeBridgeStatus] = [:]
    private(set) var routes: [UUID: ClaudeBridgeRoute] = [:]

    init(
        tokenStore: any ClaudeBridgeTokenStoring,
        notificationDelivery: any ClaudeBridgeNotificationDelivering,
        installationKey: SymmetricKey,
        statusDelivery: @escaping @MainActor @Sendable (ClaudeBridgeRoute, ClaudeBridgeStatus) -> Void
    ) throws {
        let listener = try ClaudeBridgeLoopbackListener()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: notificationDelivery
        )
        self.listener = listener
        self.service = service
        self.sessionSignals = service.sessionSignals
        self.statusDelivery = statusDelivery
        let keyData = installationKey.withUnsafeBytes { Data($0) }
        self.installationID = ClaudeBridgeInstallationIdentity.derive(from: keyData)

        Task { [weak self, listener] in
            await listener.start { [weak self] frame in
                guard let self else {
                    return Data(#"{"accepted":false,"duplicate":false,"code":"shutdown"}"#.utf8)
                }
                return await self.ingest(frame)
            }
        }
        statusTask = Task { @MainActor [weak self, service] in
            for await update in service.statusUpdates {
                guard !Task.isCancelled, let self else { return }
                guard let route = self.routes[update.routeID] else { continue }
                if update.status == .inactive {
                    self.statuses.removeValue(forKey: update.routeID)
                } else {
                    self.statuses[update.routeID] = update.status
                }
                self.statusDelivery(route, update.status)
            }
        }
    }

    func connectionPlan(for route: ClaudeBridgeRoute) -> ClaudeBridgeConnectionPlan {
        let previousOperation = registrationTasks[route.id]
        // Serialize unregister/register for a stable panel UUID. Cancelling a task
        // alone cannot revoke actor work that has already crossed an await.
        routeRebindTasks.removeValue(forKey: route.id)?.cancel()
        routes[route.id] = route
        statuses[route.id] = .reconnecting
        statusDelivery(route, .reconnecting)
        let connectionID = UUID()
        let registration = Task { [service] in
            if let previousOperation { await previousOperation.value }
            guard !Task.isCancelled else { return }
            await service.register(route: route, connectionID: connectionID)
        }
        registrationTasks[route.id] = registration
        return ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: listener.port,
            connectionID: connectionID
        )
    }

    func markReconnecting(routeID: UUID) {
        guard let route = routes[routeID] else { return }
        statuses[routeID] = .reconnecting
        statusDelivery(route, .reconnecting)
        Task { [service] in
            await service.markReconnecting(routeID: routeID)
        }
    }

    func status(for routeID: UUID) -> ClaudeBridgeStatus {
        statuses[routeID] ?? .inactive
    }

    /// Rebinds a live route to the workspace that adopted its stable terminal panel.
    func rebindRoute(
        _ routeID: UUID,
        workspaceID: UUID,
        workspaceName: String?,
        windowName: String?
    ) {
        guard let current = routes[routeID] else { return }
        let normalizedWorkspaceName = workspaceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWindowName = windowName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reboundWorkspaceName = normalizedWorkspaceName.flatMap { $0.isEmpty ? nil : $0 }
            ?? current.workspaceName
        let reboundWindowName = normalizedWindowName.flatMap { $0.isEmpty ? nil : $0 }
            ?? current.windowName
        let rebound = ClaudeBridgeRoute(
            id: current.id,
            workspaceID: workspaceID,
            surfaceID: current.surfaceID,
            credentialID: current.credentialID,
            hostLabel: current.hostLabel,
            workspaceName: reboundWorkspaceName,
            windowName: reboundWindowName,
            tmuxSession: current.tmuxSession
        )
        routes[routeID] = rebound
        let registration = registrationTasks[routeID]
        routeRebindTasks.removeValue(forKey: routeID)?.cancel()
        routeRebindTasks[routeID] = Task { [service] in
            if let registration {
                await registration.value
            }
            guard !Task.isCancelled else { return }
            _ = await service.rebind(route: rebound)
        }
    }

    func unregister(routeID: UUID, removeToken: Bool) {
        let registration = registrationTasks[routeID]
        routeRebindTasks.removeValue(forKey: routeID)?.cancel()
        let route = routes.removeValue(forKey: routeID)
        statuses.removeValue(forKey: routeID)
        if let route { statusDelivery(route, .inactive) }
        let removal = Task { [service] in
            if let registration { await registration.value }
            guard !Task.isCancelled else { return }
            await service.unregister(routeID: routeID, removeToken: removeToken)
        }
        registrationTasks[routeID] = removal
    }

    func shutdown() {
        statusTask?.cancel()
        statusTask = nil
        for task in registrationTasks.values { task.cancel() }
        registrationTasks.removeAll()
        for task in routeRebindTasks.values { task.cancel() }
        routeRebindTasks.removeAll()
        statuses.removeAll()
        routes.removeAll()
        Task { [listener, service] in
            await listener.stop()
            await service.shutdown()
        }
    }

    private nonisolated func ingest(_ frame: Data) async -> Data {
        if let envelope = try? JSONDecoder().decode(RouteEnvelope.self, from: frame),
           let registration = await registrationTask(for: envelope.routeID) {
            await registration.value
        }
        return await service.ingest(frame)
    }

    /// Snapshots the ordering barrier; waiting and replying never depend on UI scheduling.
    private func registrationTask(for routeID: UUID) -> Task<Void, Never>? {
        registrationTasks[routeID]
    }
}
