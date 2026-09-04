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
    private let service: ClaudeBridgeService
    private let installationID: String
    private let statusDelivery: @MainActor @Sendable (ClaudeBridgeRoute, ClaudeBridgeStatus) -> Void
    nonisolated let sessionSignals: AsyncStream<ClaudeBridgeSessionSignal>
    private var statusTask: Task<Void, Never>?
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
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
        registrationTasks.removeValue(forKey: route.id)?.cancel()
        routes[route.id] = route
        statuses[route.id] = .reconnecting
        statusDelivery(route, .reconnecting)
        let registration = Task { [service] in
            await service.register(route: route)
        }
        registrationTasks[route.id] = registration
        return ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: installationID,
            localListenerPort: listener.port
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

    func unregister(routeID: UUID, removeToken: Bool) {
        let registration = registrationTasks.removeValue(forKey: routeID)
        registration?.cancel()
        let route = routes.removeValue(forKey: routeID)
        statuses.removeValue(forKey: routeID)
        if let route { statusDelivery(route, .inactive) }
        Task { [service] in
            if let registration { await registration.value }
            await service.unregister(routeID: routeID, removeToken: removeToken)
        }
    }

    func shutdown() {
        statusTask?.cancel()
        statusTask = nil
        for task in registrationTasks.values { task.cancel() }
        registrationTasks.removeAll()
        statuses.removeAll()
        routes.removeAll()
        Task { [listener, service] in
            await listener.stop()
            await service.shutdown()
        }
    }

    private func ingest(_ frame: Data) async -> Data {
        if let envelope = try? JSONDecoder().decode(RouteEnvelope.self, from: frame),
           let registration = registrationTasks[envelope.routeID] {
            await registration.value
        }
        return await service.ingest(frame)
    }
}
