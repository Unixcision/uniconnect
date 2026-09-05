import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeAuthenticatorTests {
    @Test
    func acceptsValidHMACAndRejectsReplay() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x31, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let message = BridgeTestMessages.event(routeID: route.id, token: token, timestamp: now)

        let first = await authenticator.authenticate(message, expectedRouteID: route.id)
        guard case .success(let event?) = first else {
            Issue.record("Expected the signed event to authenticate")
            return
        }
        #expect(event.kind == .stop)
        #expect(event.cwd == "/srv/test")
        #expect(event.tmuxPane == "%7")
        let replay = await authenticator.authenticate(message, expectedRouteID: route.id)
        guard case .failure(.duplicate) = replay else {
            Issue.record("Expected replay rejection")
            return
        }
    }

    @Test
    func rejectsInvalidSignatureStaleAndMalformedMetadata() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x42, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)

        let badSignature = BridgeTestMessages.event(
            routeID: route.id,
            token: Data(repeating: 0x99, count: 32),
            timestamp: now
        )
        let badSignatureResult = await authenticator.authenticate(badSignature, expectedRouteID: route.id)
        guard case .failure(.unauthenticated) = badSignatureResult else {
            Issue.record("Expected invalid signature rejection")
            return
        }

        let stale = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-301),
            eventID: String(repeating: "c", count: 64)
        )
        let staleResult = await authenticator.authenticate(stale, expectedRouteID: route.id)
        guard case .failure(.stale) = staleResult else {
            Issue.record("Expected stale event rejection")
            return
        }

        let malformed = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "d", count: 64),
            cwd: "relative/private"
        )
        let malformedResult = await authenticator.authenticate(malformed, expectedRouteID: route.id)
        guard case .failure(.malformed) = malformedResult else {
            Issue.record("Expected malformed metadata rejection")
            return
        }
    }

    @Test
    func coalescesStopAndIdlePromptForSameCompletion() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x53, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let stop = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-60)
        )
        let idle = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "e", count: 64),
            kind: .idlePrompt
        )

        guard case .success = await authenticator.authenticate(stop, expectedRouteID: route.id) else {
            Issue.record("Expected Stop to authenticate")
            return
        }
        let idleResult = await authenticator.authenticate(idle, expectedRouteID: route.id)
        guard case .failure(.duplicate) = idleResult else {
            Issue.record("Expected Stop/idle_prompt coalescing")
            return
        }
    }

    @Test
    func coalescesComplementaryCompletionAfterWorkingDirectoryChange() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x57, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let stop = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-60),
            cwd: "/srv/before"
        )
        let idle = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "1", count: 64),
            kind: .idlePrompt,
            cwd: "/srv/after"
        )

        guard case .success = await authenticator.authenticate(stop, expectedRouteID: route.id) else {
            Issue.record("Expected Stop to authenticate")
            return
        }
        guard case .failure(.duplicate) = await authenticator.authenticate(
            idle,
            expectedRouteID: route.id
        ) else {
            Issue.record("A cwd change must not split one Stop/idle_prompt completion")
            return
        }
    }

    @Test
    func delayedOlderCompletionCannotRewindCoalescingState() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x58, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let newestStop = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-30)
        )
        let delayedOlderStop = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-120),
            eventID: String(repeating: "2", count: 64)
        )
        let matchingIdle = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "3", count: 64),
            kind: .idlePrompt
        )

        guard case .success = await authenticator.authenticate(
            newestStop,
            expectedRouteID: route.id
        ) else {
            Issue.record("Expected newest Stop to authenticate")
            return
        }
        guard case .failure(.duplicate) = await authenticator.authenticate(
            delayedOlderStop,
            expectedRouteID: route.id
        ) else {
            Issue.record("An older completion must not be surfaced after a newer one")
            return
        }
        guard case .failure(.duplicate) = await authenticator.authenticate(
            matchingIdle,
            expectedRouteID: route.id
        ) else {
            Issue.record("The rejected old event must not rewind completion coalescing")
            return
        }
    }

    @Test
    func coalescedCompletionStillConsumesItsReplayIdentifier() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = ClaudeBridgeTestClock(initialDate)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x59, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { clock.now() })
        await authenticator.register(token: token, for: route.id)
        let stop = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: initialDate
        )
        let idle = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: initialDate.addingTimeInterval(1),
            eventID: String(repeating: "9", count: 64),
            kind: .idlePrompt
        )

        guard case .success = await authenticator.authenticate(stop, expectedRouteID: route.id) else {
            Issue.record("Expected Stop to authenticate")
            return
        }
        clock.advance(by: 1)
        guard case .failure(.duplicate) = await authenticator.authenticate(
            idle,
            expectedRouteID: route.id
        ) else {
            Issue.record("Expected the complementary completion to coalesce")
            return
        }

        clock.advance(by: 100)
        guard case .failure(.duplicate) = await authenticator.authenticate(
            idle,
            expectedRouteID: route.id
        ) else {
            Issue.record("A coalesced frame must remain replay-protected after correlation state expires")
            return
        }
    }

    @Test
    func replayRetentionCannotBeConfiguredBelowTheFreshnessWindow() async {
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = ClaudeBridgeTestClock(initialDate)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x5A, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(
            maximumAge: 60,
            futureTolerance: 5,
            replayRetention: 1,
            now: { clock.now() }
        )
        await authenticator.register(token: token, for: route.id)
        let event = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: initialDate
        )

        guard case .success = await authenticator.authenticate(event, expectedRouteID: route.id) else {
            Issue.record("Expected the original event to authenticate")
            return
        }
        clock.advance(by: 2)
        guard case .failure(.duplicate) = await authenticator.authenticate(
            event,
            expectedRouteID: route.id
        ) else {
            Issue.record("Replay retention must cover every still-fresh event")
            return
        }
    }

    @Test
    func doesNotCoalesceTwoDistinctStopCompletions() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x54, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let first = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now.addingTimeInterval(-30)
        )
        let second = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "8", count: 64)
        )

        guard case .success = await authenticator.authenticate(first, expectedRouteID: route.id) else {
            Issue.record("Expected first Stop to authenticate")
            return
        }
        guard case .success = await authenticator.authenticate(second, expectedRouteID: route.id) else {
            Issue.record("A later Stop represents a distinct completion")
            return
        }
    }

    @Test
    func rejectsEnrollmentReplayWithoutCollidingAcrossRoutes() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstRoute = BridgeTestMessages.route()
        let secondRoute = BridgeTestMessages.route()
        let token = Data(repeating: 0x55, count: 32)
        let eventID = String(repeating: "7", count: 64)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        let first = BridgeTestMessages.enrollment(
            routeID: firstRoute.id,
            token: token,
            timestamp: now,
            eventID: eventID
        )
        let second = BridgeTestMessages.enrollment(
            routeID: secondRoute.id,
            token: token,
            timestamp: now,
            eventID: eventID
        )

        guard case .success = await authenticator.acceptEnrollment(first, expectedRouteID: firstRoute.id) else {
            Issue.record("Expected first enrollment to be accepted")
            return
        }
        guard case .failure(.duplicate) = await authenticator.acceptEnrollment(
            first,
            expectedRouteID: firstRoute.id
        ) else {
            Issue.record("Expected enrollment replay rejection")
            return
        }
        guard case .success = await authenticator.acceptEnrollment(second, expectedRouteID: secondRoute.id) else {
            Issue.record("Replay identifiers are scoped to their trusted route")
            return
        }
    }

    @Test
    func malformedSignedFrameDoesNotConsumeItsReplayIdentifier() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x64, count: 32)
        let eventID = String(repeating: "f", count: 64)
        let authenticator = ClaudeBridgeAuthenticator(now: { now })
        await authenticator.register(token: token, for: route.id)
        let malformed = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: eventID,
            cwd: "relative"
        )
        let malformedResult = await authenticator.authenticate(malformed, expectedRouteID: route.id)
        guard case .failure(.malformed) = malformedResult else {
            Issue.record("Expected malformed metadata rejection")
            return
        }

        let corrected = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: eventID
        )
        let correctedResult = await authenticator.authenticate(corrected, expectedRouteID: route.id)
        guard case .success = correctedResult else {
            Issue.record("A rejected malformed frame must not poison replay state")
            return
        }
    }

    @Test
    func boundsReplayStatePerRouteWithoutBlockingIndependentRoutes() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstRoute = BridgeTestMessages.route()
        let secondRoute = BridgeTestMessages.route()
        let token = Data(repeating: 0x65, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(
            maximumReplayEntries: 2,
            maximumReplayEntriesPerRoute: 1,
            now: { now }
        )
        await authenticator.register(token: token, for: firstRoute.id)
        await authenticator.register(token: token, for: secondRoute.id)

        let first = BridgeTestMessages.event(
            routeID: firstRoute.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "4", count: 64)
        )
        let overflow = BridgeTestMessages.event(
            routeID: firstRoute.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "5", count: 64),
            kind: .sessionStart
        )
        let independent = BridgeTestMessages.event(
            routeID: secondRoute.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "6", count: 64)
        )

        guard case .success = await authenticator.authenticate(first, expectedRouteID: firstRoute.id) else {
            Issue.record("Expected the first route event to authenticate")
            return
        }
        guard case .failure(.capacity) = await authenticator.authenticate(
            overflow,
            expectedRouteID: firstRoute.id
        ) else {
            Issue.record("Expected bounded replay state to fail closed for one noisy route")
            return
        }
        guard case .success = await authenticator.authenticate(
            independent,
            expectedRouteID: secondRoute.id
        ) else {
            Issue.record("One route reaching its cap must not block another route")
            return
        }
    }

    @Test
    func boundsCompletionCorrelationState() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let route = BridgeTestMessages.route()
        let token = Data(repeating: 0x66, count: 32)
        let authenticator = ClaudeBridgeAuthenticator(
            maximumCompletionEntries: 1,
            maximumCompletionEntriesPerRoute: 1,
            now: { now }
        )
        await authenticator.register(token: token, for: route.id)
        let first = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "7", count: 64),
            sessionID: "11111111-2222-4333-8444-555555555555"
        )
        let overflow = BridgeTestMessages.event(
            routeID: route.id,
            token: token,
            timestamp: now,
            eventID: String(repeating: "8", count: 64),
            sessionID: "22222222-3333-4444-8555-666666666666"
        )

        guard case .success = await authenticator.authenticate(first, expectedRouteID: route.id) else {
            Issue.record("Expected the first completion to authenticate")
            return
        }
        guard case .failure(.capacity) = await authenticator.authenticate(
            overflow,
            expectedRouteID: route.id
        ) else {
            Issue.record("Expected bounded completion correlation state to fail closed")
            return
        }
    }
}

private final class ClaudeBridgeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date.addTimeInterval(interval)
        lock.unlock()
    }
}
