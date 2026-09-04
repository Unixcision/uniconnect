import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeServiceTests {
    @MainActor
    @Test
    func reportsReconnectThenUnavailableWithoutPolling() async {
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let sleeper = BridgeTestSleeper()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )
        let route = BridgeTestMessages.route()
        var updates = service.statusUpdates.makeAsyncIterator()
        await service.register(route: route)
        let reconnecting = await updates.next()
        #expect(reconnecting == .init(routeID: route.id, status: .reconnecting))

        await sleeper.waitUntilSleeping()
        await sleeper.fire()
        let unavailable = await updates.next()
        #expect(unavailable == .init(routeID: route.id, status: .unavailable(.enrollmentTimedOut)))
        await service.shutdown()
    }

    @MainActor
    @Test
    func enrollsThenDeliversToExactTrustedRouteAndRejectsReplay() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x71, count: 32)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        var sessionSignals = service.sessionSignals.makeAsyncIterator()
        await service.register(route: route)

        let enrollment = BridgeTestMessages.enrollment(routeID: route.id, token: token, timestamp: now)
        let enrollmentResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )
        #expect(enrollmentResponse.accepted)
        let activeStatus = await service.status(for: route.id)
        let storedToken = try await tokenStore.token(for: route.id)
        #expect(activeStatus == .active)
        #expect(storedToken == token)

        let enrollmentReplay = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )
        #expect(!enrollmentReplay.accepted)
        #expect(enrollmentReplay.duplicate)

        let event = BridgeTestMessages.event(routeID: route.id, token: token, timestamp: now)
        let firstResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(event))
        )
        #expect(firstResponse.accepted)
        #expect(delivery.deliveries.count == 1)
        #expect(delivery.deliveries.first?.1.workspaceID == route.workspaceID)
        #expect(delivery.deliveries.first?.1.surfaceID == route.surfaceID)
        let signal = await sessionSignals.next()
        #expect(signal == ClaudeBridgeSessionSignal(
            routeID: route.id,
            sessionID: "11111111-2222-4333-8444-555555555555",
            cwd: "/srv/test",
            tmuxPane: "%7",
            kind: .stop,
            occurredAt: now
        ))

        let duplicateResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(event))
        )
        #expect(duplicateResponse.duplicate)
        #expect(delivery.deliveries.count == 1)
        await service.shutdown()
    }

    @MainActor
    @Test
    func keepsTokensAndRoutesIndependentAcrossHosts() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        let credentialA = UUID()
        let credentialB = UUID()
        let routeA = BridgeTestMessages.route(credentialID: credentialA, host: "host-a", tmuxSession: "a")
        let routeB = BridgeTestMessages.route(credentialID: credentialB, host: "host-b", tmuxSession: "b")
        let tokenA = Data(repeating: 0x11, count: 32)
        let tokenB = Data(repeating: 0x22, count: 32)
        await service.register(route: routeA)
        await service.register(route: routeB)
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.enrollment(routeID: routeA.id, token: tokenA, timestamp: now)
        ))
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.enrollment(routeID: routeB.id, token: tokenB, timestamp: now)
        ))

        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.event(routeID: routeA.id, token: tokenA, timestamp: now)
        ))
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.event(
                routeID: routeB.id,
                token: tokenB,
                timestamp: now,
                eventID: String(repeating: "c", count: 64),
                cwd: "/srv/other",
                pane: "%8"
            )
        ))

        #expect(delivery.deliveries.count == 2)
        #expect(Set(delivery.deliveries.map { $0.1.hostLabel }) == ["host-a", "host-b"])
        let routesA = await service.routeIDs(for: credentialA)
        let routesB = await service.routeIDs(for: credentialB)
        #expect(routesA == [routeA.id])
        #expect(routesB == [routeB.id])
        await service.shutdown()
    }

    @MainActor
    @Test
    func refusesMismatchedReenrollmentAndInvalidSignature() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let originalToken = Data(repeating: 0x33, count: 32)
        try await tokenStore.store(token: originalToken, for: route.id, credentialID: route.credentialID)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route)

        let replacement = BridgeTestMessages.enrollment(
            routeID: route.id,
            token: Data(repeating: 0x44, count: 32),
            timestamp: now
        )
        let replacementResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(replacement))
        )
        #expect(!replacementResponse.accepted)
        #expect(replacementResponse.code == "token_mismatch")

        let invalidEvent = BridgeTestMessages.event(
            routeID: route.id,
            token: Data(repeating: 0x55, count: 32),
            timestamp: now
        )
        let invalidResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(invalidEvent))
        )
        #expect(!invalidResponse.accepted)
        #expect(invalidResponse.code == "unauthenticated")
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
    }

    @MainActor
    @Test
    func sessionStartPublishesInternalSignalWithoutUserNotification() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x79, count: 32)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        var signals = service.sessionSignals.makeAsyncIterator()
        await service.register(route: route)
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.enrollment(routeID: route.id, token: token, timestamp: now)
        ))
        let sessionStart = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "9", count: 64),
            kind: .sessionStart
        )

        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(sessionStart))
        )
        let signal = await signals.next()

        #expect(response.accepted)
        #expect(signal?.kind == .sessionStart)
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
    }

    @MainActor
    @Test
    func userPromptPublishesRunningSignalWithoutUserNotification() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x7A, count: 32)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        var signals = service.sessionSignals.makeAsyncIterator()
        await service.register(route: route)
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.enrollment(routeID: route.id, token: token, timestamp: now)
        ))
        let prompt = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "8", count: 64),
            kind: .userPromptSubmit
        )

        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(prompt))
        )
        let signal = await signals.next()

        #expect(response.accepted)
        #expect(signal?.kind == .userPromptSubmit)
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
    }
}
