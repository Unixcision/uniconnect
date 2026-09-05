import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeServiceTests {
    @MainActor
    @Test
    func connectionEnrollmentNeedsSignedPublicationConfirmationBeforeBecomingActive() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let connectionID = UUID()
        let token = Data(repeating: 0x6D, count: 32)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route, connectionID: connectionID)
        let enrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: token, timestamp: now, connectionID: connectionID
        )
        let enrollmentResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )
        #expect(enrollmentResponse.accepted)
        #expect(await service.status(for: route.id) == .reconnecting)

        let supersededHello = BridgeTestMessages.hello(
            routeID: route.id, token: token, timestamp: now, connectionID: UUID()
        )
        let supersededResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(supersededHello))
        )
        #expect(supersededResponse.code == "superseded")
        #expect(await service.status(for: route.id) == .reconnecting)

        let invalidHello = BridgeTestMessages.hello(
            routeID: route.id, token: Data(repeating: 0x6E, count: 32),
            timestamp: now, connectionID: connectionID
        )
        let invalidResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(invalidHello))
        )
        #expect(invalidResponse.code == "unauthenticated")
        #expect(await service.status(for: route.id) == .error(.authentication))

        let hello = BridgeTestMessages.hello(
            routeID: route.id, token: token, timestamp: now, connectionID: connectionID
        )
        let helloResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(hello))
        )
        #expect(helloResponse.accepted)
        #expect(await service.status(for: route.id) == .active)
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
        var activeUpdates = 0
        for await update in service.statusUpdates {
            if update.status == .active { activeUpdates += 1 }
        }
        #expect(activeUpdates == 1)
        var signals = service.sessionSignals.makeAsyncIterator()
        #expect(await signals.next() == nil)
    }

    @MainActor
    @Test
    func acceptedEnrollmentKeepsDeadlineArmedUntilRemotePublicationIsConfirmed() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sleeper = BridgeTestSleeper()
        let route = BridgeTestMessages.route()
        let connectionID = UUID()
        let service = ClaudeBridgeService(
            tokenStore: BridgeTestTokenStore(),
            notificationDelivery: BridgeTestNotificationDelivery(),
            now: { now },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )
        var updates = service.statusUpdates.makeAsyncIterator()
        await service.register(route: route, connectionID: connectionID)
        #expect(await updates.next()?.status == .reconnecting)
        await sleeper.waitUntilSleeping()
        let enrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: Data(repeating: 0x6F, count: 32),
            timestamp: now, connectionID: connectionID
        )
        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )
        #expect(response.accepted)
        #expect(await service.status(for: route.id) == .reconnecting)

        await sleeper.fire()
        #expect(await updates.next()?.status == .unavailable(.enrollmentTimedOut))
        #expect(await service.status(for: route.id) == .unavailable(.enrollmentTimedOut))
        await service.shutdown()
    }

    @MainActor
    @Test(arguments: [false, true])
    func integrationFailureNeverWaitsForPublicationOrClaimsReadiness(boundConnection: Bool) async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let connectionID: UUID? = boundConnection ? UUID() : nil
        let service = ClaudeBridgeService(
            tokenStore: BridgeTestTokenStore(),
            notificationDelivery: BridgeTestNotificationDelivery(),
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route, connectionID: connectionID)
        let enrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: Data(repeating: 0x70, count: 32),
            timestamp: now, ready: false, error: "settings_invalid", connectionID: connectionID
        )
        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )

        #expect(response.accepted)
        #expect(await service.status(for: route.id) == .unavailable(.remoteSettings))
        await service.shutdown()
    }

    @MainActor
    @Test
    func reconnectRejectsSupersededEnrollmentAndEventsWithoutChangingCurrentStatus() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x6A, count: 32)
        let previousConnectionID = UUID()
        let currentConnectionID = UUID()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route, connectionID: previousConnectionID)
        let initialEnrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: token, timestamp: now,
            connectionID: previousConnectionID
        )
        let initialResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(initialEnrollment))
        )
        #expect(initialResponse.accepted)

        await service.register(route: route, connectionID: currentConnectionID)
        let supersededEnrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: token, timestamp: now,
            eventID: String(repeating: "c", count: 64), ready: false,
            error: "settings_invalid", connectionID: previousConnectionID
        )
        let supersededEvent = BridgeTestMessages.event(
            routeID: route.id, token: token, timestamp: now,
            connectionID: previousConnectionID
        )
        let legacyEnrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: token, timestamp: now,
            eventID: String(repeating: "d", count: 64)
        )
        for message in [supersededEnrollment, supersededEvent, legacyEnrollment] {
            let response = try JSONDecoder().decode(
                ClaudeBridgeIngestResponse.self,
                from: await service.ingest(BridgeTestMessages.data(message))
            )
            #expect(!response.accepted)
            #expect(response.code == "superseded")
            #expect(await service.status(for: route.id) == .reconnecting)
        }
        #expect(delivery.deliveries.isEmpty)

        let currentEnrollment = BridgeTestMessages.enrollment(
            routeID: route.id, token: token, timestamp: now,
            eventID: String(repeating: "e", count: 64), connectionID: currentConnectionID
        )
        let enrollmentResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(currentEnrollment))
        )
        #expect(enrollmentResponse.accepted)
        var forgedEvent = supersededEvent
        forgedEvent.connectionID = currentConnectionID.uuidString.lowercased()
        let forgedResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(forgedEvent))
        )
        #expect(!forgedResponse.accepted)
        #expect(forgedResponse.code == "unauthenticated")
        #expect(delivery.deliveries.isEmpty)
        let currentEvent = BridgeTestMessages.event(
            routeID: route.id, token: token, timestamp: now,
            connectionID: currentConnectionID
        )
        let eventResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(currentEvent))
        )
        #expect(eventResponse.accepted)
        #expect(await service.status(for: route.id) == .active)
        #expect(delivery.deliveries.count == 1)
        await service.shutdown()
        var signals = service.sessionSignals.makeAsyncIterator()
        #expect(await signals.next()?.kind == .stop)
        #expect(await signals.next() == nil)
    }

    @MainActor
    @Test(arguments: [false, true])
    func supersededTokenPersistenceCannotPublishStatusForReplacement(failingStore: Bool) async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let suspension = BridgeTestSleeper()
        let route = BridgeTestMessages.route()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route)
        await tokenStore.suspendNextStore(using: suspension, thenFail: failingStore)
        let message = try BridgeTestMessages.data(BridgeTestMessages.enrollment(
            routeID: route.id, token: Data(repeating: 0x6B, count: 32), timestamp: now
        ))
        let pending = Task { await service.ingest(message) }
        await suspension.waitUntilSleeping()
        await service.register(route: route)
        await suspension.fire()
        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self, from: await pending.value
        )

        #expect(!response.accepted)
        #expect(response.code == "route_changed")
        #expect(await service.status(for: route.id) == .reconnecting)
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
    }

    @MainActor
    @Test(arguments: [false, true])
    func cancelledEnrollmentCannotBecomeActiveOrPublishPersistenceFailure(failingStore: Bool) async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let suspension = BridgeTestSleeper()
        let route = BridgeTestMessages.route()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route)
        await tokenStore.suspendNextStore(using: suspension, thenFail: failingStore)
        let message = try BridgeTestMessages.data(BridgeTestMessages.enrollment(
            routeID: route.id, token: Data(repeating: 0x6C, count: 32), timestamp: now
        ))
        let pending = Task { await service.ingest(message) }
        await suspension.waitUntilSleeping()
        pending.cancel()
        await suspension.fire()
        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self, from: await pending.value
        )

        #expect(!response.accepted)
        #expect(response.code == "route_changed")
        #expect(await service.status(for: route.id) == .reconnecting)
        #expect(delivery.deliveries.isEmpty)
        await service.shutdown()
    }

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
        let storedToken = try await tokenStore.token(
            for: route.id,
            credentialID: route.credentialID
        )
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
    func rebindsOnlyWorkspaceMetadataForTheSameConnectionIdentity() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x72, count: 32)
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        await service.register(route: route)
        _ = await service.ingest(try BridgeTestMessages.data(
            BridgeTestMessages.enrollment(routeID: route.id, token: token, timestamp: now)
        ))
        let rebound = ClaudeBridgeRoute(
            id: route.id,
            workspaceID: UUID(),
            surfaceID: route.surfaceID,
            credentialID: route.credentialID,
            hostLabel: route.hostLabel,
            workspaceName: "Moved",
            windowName: "Moved Claude",
            tmuxSession: route.tmuxSession
        )
        let wrongIdentity = ClaudeBridgeRoute(
            id: route.id,
            workspaceID: rebound.workspaceID,
            surfaceID: route.surfaceID,
            credentialID: UUID(),
            hostLabel: route.hostLabel,
            workspaceName: rebound.workspaceName,
            windowName: rebound.windowName,
            tmuxSession: route.tmuxSession
        )

        #expect(await service.rebind(route: rebound))
        #expect(!(await service.rebind(route: wrongIdentity)))
        let event = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "7", count: 64)
        )
        let response = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(event))
        )

        #expect(response.accepted)
        #expect(delivery.deliveries.last?.1.workspaceID == rebound.workspaceID)
        #expect(delivery.deliveries.last?.1.workspaceName == "Moved")
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
    func changingCredentialForStableRouteRequiresFreshHostEnrollment() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = BridgeTestTokenStore()
        let delivery = BridgeTestNotificationDelivery()
        let service = ClaudeBridgeService(
            tokenStore: tokenStore,
            notificationDelivery: delivery,
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        let routeID = UUID()
        let oldCredentialID = UUID()
        let newCredentialID = UUID()
        let oldRoute = BridgeTestMessages.route(
            id: routeID,
            credentialID: oldCredentialID,
            host: "old-host"
        )
        let newRoute = BridgeTestMessages.route(
            id: routeID,
            workspaceID: oldRoute.workspaceID,
            surfaceID: oldRoute.surfaceID,
            credentialID: newCredentialID,
            host: "new-host"
        )
        let oldToken = Data(repeating: 0x31, count: 32)
        let newToken = Data(repeating: 0x32, count: 32)
        try await tokenStore.store(
            token: oldToken,
            for: routeID,
            credentialID: oldCredentialID
        )
        await service.register(route: oldRoute)
        let oldEvent = BridgeTestMessages.event(
            routeID: routeID,
            token: oldToken,
            timestamp: now,
            eventID: String(repeating: "3", count: 64)
        )
        let oldResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(oldEvent))
        )
        #expect(oldResponse.accepted)

        await service.register(route: newRoute)
        let staleHostEvent = BridgeTestMessages.event(
            routeID: routeID,
            token: oldToken,
            timestamp: now,
            eventID: String(repeating: "4", count: 64)
        )
        let staleHostResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(staleHostEvent))
        )
        #expect(staleHostResponse.code == "unauthenticated")

        let enrollment = BridgeTestMessages.enrollment(
            routeID: routeID,
            token: newToken,
            timestamp: now,
            eventID: String(repeating: "5", count: 64)
        )
        let enrollmentResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(enrollment))
        )
        #expect(enrollmentResponse.accepted)
        let newEvent = BridgeTestMessages.event(
            routeID: routeID,
            token: newToken,
            timestamp: now,
            eventID: String(repeating: "6", count: 64)
        )
        let newResponse = try JSONDecoder().decode(
            ClaudeBridgeIngestResponse.self,
            from: await service.ingest(BridgeTestMessages.data(newEvent))
        )

        #expect(newResponse.accepted)
        #expect(delivery.deliveries.map { $0.1.hostLabel } == ["old-host", "new-host"])
        #expect(await service.routeIDs(for: oldCredentialID).isEmpty)
        #expect(await service.routeIDs(for: newCredentialID) == [routeID])
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
