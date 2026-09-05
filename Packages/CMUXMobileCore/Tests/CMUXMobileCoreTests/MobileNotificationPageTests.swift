import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Retained notification replay")
struct MobileNotificationPageTests {
    @Test func listAndEventUseTheSameDurableIdentityAndWireFields() throws {
        let notification = record(1, timestamp: 1_000)
        let page = try MobileNotificationPage(records: [notification])
        let event = notification.jsonObject()
        let listed = try #require((page.jsonObject()["notifications"] as? [[String: Any]])?.first)
        #expect(event["id"] as? String == notification.id)
        #expect(listed["id"] as? String == event["id"] as? String)
        #expect(listed["created_at_ms"] as? Int64 == 1_000)
        #expect(listed["created_at"] as? String == notification.createdAt)
        #expect(listed["surface_id"] is NSNull)
        #expect(listed["is_read"] as? Bool == false)
        #expect(try JSONSerialization.data(withJSONObject: page.jsonObject()).count < 8 * 1024 * 1024)
        let restored = try JSONDecoder().decode(MobileNotificationRecord.self, from: JSONEncoder().encode(notification))
        #expect(restored.id == notification.id)
    }

    @Test func cursorSurvivesDeletingItsAnchorAndNewerArrivals() throws {
        let initial = (1...5).map { record($0, timestamp: Int64($0 * 1_000)) }
        let first = try MobileNotificationPage(records: initial, limit: 2)
        #expect(first.notifications.map(\.id) == [uuid(5), uuid(4)])
        let cursor = try #require(first.nextCursor)
        let current = initial.filter { $0.id != uuid(4) } + [record(6, timestamp: 6_000)]
        let second = try MobileNotificationPage(records: current, limit: 2, before: cursor)
        #expect(second.notifications.map(\.id) == [uuid(3), uuid(2)])
        let third = try MobileNotificationPage(records: current, limit: 2, before: #require(second.nextCursor))
        #expect(third.notifications.map(\.id) == [uuid(1)])
        #expect(third.nextCursor == nil)
    }

    @Test func equalTimestampsAreOrderedByDurableIDWithoutPageDuplicates() throws {
        let records = (1...3).map { record($0, timestamp: 1_000) }
        let first = try MobileNotificationPage(records: records, limit: 1)
        #expect(first.notifications.map(\.id) == [uuid(3)])
        let second = try MobileNotificationPage(records: records, limit: 2, before: #require(first.nextCursor))
        #expect(second.notifications.map(\.id) == [uuid(2), uuid(1)])
    }

    @Test func retainedDuplicateIDsAppearOnlyOnceAndReadingDoesNotAcknowledge() throws {
        let notification = record(1, timestamp: 1_000)
        let page = try MobileNotificationPage(records: [notification, notification])
        #expect(page.notifications.count == 1)
        #expect(!page.notifications[0].isRead)
        #expect(!notification.isRead)
    }

    @Test(arguments: [0, -1, 201])
    func rejectsInvalidLimits(_ limit: Int) {
        #expect(throws: MobileNotificationPageError.invalidLimit) {
            try MobileNotificationPage(records: [], limit: limit)
        }
    }

    @Test(arguments: ["", "!", "e30", String(repeating: "a", count: 513)])
    func rejectsMalformedOpaqueCursors(_ cursor: String) {
        #expect(throws: MobileNotificationPageError.invalidCursor) {
            try MobileNotificationPage(records: [], before: cursor)
        }
    }

    @Test func unicodeAndCombiningMarksCannotEvadeByteCaps() throws {
        let text = String(repeating: "A\u{0301}🛰", count: 10_000)
        let notification = MobileNotificationRecord(id: uuid(1), workspaceID: uuid(2), surfaceID: nil, title: text, subtitle: text, body: text, createdAtMilliseconds: 1_000, isRead: false)
        #expect(notification.title.utf8.count <= 512)
        #expect(notification.subtitle.utf8.count <= 512)
        #expect(notification.body.utf8.count <= 4096)
        #expect(!notification.body.contains("\u{fffd}"))
    }

    private func uuid(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }

    private func record(_ value: Int, timestamp: Int64) -> MobileNotificationRecord {
        MobileNotificationRecord(id: uuid(value), workspaceID: uuid(100), surfaceID: nil, title: "Completado", subtitle: "", body: "Aviso de prueba", createdAtMilliseconds: timestamp, isRead: false)
    }
}
