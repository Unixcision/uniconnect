import Foundation

/// Stable newest-first pagination over the notifications retained by a desktop.
///
/// This is not an infinite event history: a desktop may replace or remove older
/// notices. Timestamp-and-identity cursors remain usable when an entry is deleted.
public struct MobileNotificationPage: Sendable {
    /// The retained notices in descending timestamp and identity order.
    public let notifications: [MobileNotificationRecord]
    /// An opaque cursor for the next older page, or `nil` at the end.
    public let nextCursor: String?

    /// Selects one page without changing any notification or read state.
    /// - Parameters:
    ///   - records: Snapshots of the authoritative desktop notification store.
    ///   - limit: The requested page size, between 1 and 200.
    ///   - before: An opaque cursor previously returned by this protocol.
    /// - Throws: ``MobileNotificationPageError`` for an invalid limit or cursor.
    public init(records: [MobileNotificationRecord], limit: Int = 100, before: String? = nil) throws {
        guard (1...200).contains(limit) else { throw MobileNotificationPageError.invalidLimit }
        let cursor = try before.map(Cursor.decode)
        var seen = Set<String>()
        let eligible = records.sorted { lhs, rhs in
            if lhs.createdAtMilliseconds != rhs.createdAtMilliseconds { return lhs.createdAtMilliseconds > rhs.createdAtMilliseconds }
            return lhs.id > rhs.id
        }.filter { record in
            guard seen.insert(record.id).inserted else { return false }
            guard let cursor else { return true }
            return record.createdAtMilliseconds < cursor.createdAtMilliseconds
                || (record.createdAtMilliseconds == cursor.createdAtMilliseconds && record.id < cursor.id)
        }
        notifications = Array(eligible.prefix(limit))
        if eligible.count > limit, let last = notifications.last {
            nextCursor = try Cursor(createdAtMilliseconds: last.createdAtMilliseconds, id: last.id).encoded()
        } else { nextCursor = nil }
    }

    /// Returns the mobile RPC result object for this read-only page.
    /// - Returns: The notification array and its optional continuation cursor.
    public func jsonObject() -> [String: Any] {
        ["notifications": notifications.map { $0.jsonObject() }, "next_cursor": nextCursor as Any? ?? NSNull()]
    }

    private struct Cursor: Codable {
        let createdAtMilliseconds: Int64
        let id: String
        enum CodingKeys: String, CodingKey {
            case createdAtMilliseconds = "created_at_ms"
            case id
        }
        func encoded() throws -> String {
            try JSONEncoder().encode(self).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        static func decode(_ encoded: String) throws -> Cursor {
            guard !encoded.isEmpty, encoded.utf8.count <= 512,
                  encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw MobileNotificationPageError.invalidCursor
            }
            var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                  UUID(uuidString: cursor.id) != nil else { throw MobileNotificationPageError.invalidCursor }
            return cursor
        }
    }
}
