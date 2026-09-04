import Foundation
import Testing
@testable import UniConnectClaudeBridge

struct ClaudeBridgeRemoteSessionRecordTests {
    @Test
    func decodesFreshExactUUIDContractForUpdater() throws {
        let routeID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let sessionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let json = """
        {"version":1,"route_id":"\(routeID.uuidString.lowercased())","session_id":"\(sessionID.uuidString.lowercased())","session_kind":"uuid","cwd":"/srv/app","tmux_pane":"%9","activity_state":"idle","prompt_correlation":"\(String(repeating: "a", count: 64))","observed_at_ms":2000000000000}
        """
        let record = try JSONDecoder().decode(
            ClaudeBridgeRemoteSessionRecord.self,
            from: Data(json.utf8)
        )

        #expect(record.isValid(expectedRouteID: routeID, now: now))
        #expect(record.resumableSessionID == sessionID)
        #expect(record.activityState == .idle)
        #expect(record.promptCorrelation == String(repeating: "a", count: 64))
    }

    @Test
    func rejectsStaleWrongRouteAndCorrelationForResume() throws {
        let routeID = UUID()
        let record = ClaudeBridgeRemoteSessionRecord(
            version: 1,
            routeID: routeID,
            sessionID: String(repeating: "a", count: 64),
            sessionKind: .correlation,
            cwd: "/srv/app",
            tmuxPane: "%1",
            activityState: .running,
            observedAtMilliseconds: 1_999_000_000_000
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(!record.isValid(expectedRouteID: UUID(), now: now))
        #expect(!record.isValid(expectedRouteID: routeID, now: now))
        #expect(record.resumableSessionID == nil)
    }

    @Test
    func decodesLegacyIdleOnlyTimestampWithoutWeakeningFreshness() throws {
        let routeID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let sessionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let json = """
        {"version":1,"route_id":"\(routeID.uuidString.lowercased())","session_id":"\(sessionID.uuidString.lowercased())","session_kind":"uuid","cwd":"/srv/app","tmux_pane":"%9","updated_at_ms":2000000000000}
        """

        let record = try JSONDecoder().decode(
            ClaudeBridgeRemoteSessionRecord.self,
            from: Data(json.utf8)
        )

        #expect(record.activityState == .idle)
        #expect(record.observedAtMilliseconds == 2_000_000_000_000)
    }
}
