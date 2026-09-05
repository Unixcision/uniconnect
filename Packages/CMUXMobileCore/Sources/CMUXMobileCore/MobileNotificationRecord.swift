import Foundation

/// A retained terminal notification shared by list replay and live events.
///
/// Identity comes from the desktop notification store and survives its session
/// snapshots. Reading this value never marks the desktop notification as read.
public struct MobileNotificationRecord: Codable, Equatable, Sendable {
    /// The durable notification UUID; clients deduplicate it together with host identity.
    public let id: String
    /// The existing workspace to reveal, without creating or resetting sessions.
    public let workspaceID: String
    /// The existing terminal panel, or `nil` for a workspace-level notice.
    public let surfaceID: String?
    /// The retained title, limited to 512 UTF-8 bytes on the portable wire.
    public let title: String
    /// The retained subtitle, limited to 512 UTF-8 bytes on the portable wire.
    public let subtitle: String
    /// The retained body, limited to 4096 UTF-8 bytes on the portable wire.
    public let body: String
    /// The UTC creation time in ISO 8601 with fractional seconds.
    public let createdAt: String
    /// The creation time in Unix milliseconds, used for stable pagination.
    public let createdAtMilliseconds: Int64
    /// Whether the authoritative desktop notification has already been read.
    public let isRead: Bool

    /// Creates a bounded portable snapshot of an existing notification.
    /// - Parameters:
    ///   - id: The notification's durable UUID string.
    ///   - workspaceID: The current containing workspace identity.
    ///   - surfaceID: The current terminal panel identity, when applicable.
    ///   - title: The notification title, truncated to the wire limit.
    ///   - subtitle: The notification subtitle, truncated to the wire limit.
    ///   - body: The notification body, truncated to the wire limit.
    ///   - createdAtMilliseconds: The notification's original Unix timestamp.
    ///   - isRead: The desktop's current read state.
    public init(id: String, workspaceID: String, surfaceID: String?, title: String, subtitle: String, body: String, createdAtMilliseconds: Int64, isRead: Bool) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = Self.bounded(title, utf8Bytes: 512)
        self.subtitle = Self.bounded(subtitle, utf8Bytes: 512)
        self.body = Self.bounded(body, utf8Bytes: 4096)
        self.createdAtMilliseconds = createdAtMilliseconds
        createdAt = Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1000).ISO8601Format(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
        self.isRead = isRead
    }

    /// Returns the JSON object used unchanged in list responses and event payloads.
    /// - Returns: A bounded, JSON-compatible notification record.
    public func jsonObject() -> [String: Any] {
        [
            "id": id, "workspace_id": workspaceID, "surface_id": surfaceID as Any? ?? NSNull(),
            "title": title, "subtitle": subtitle, "body": body,
            "created_at": createdAt, "created_at_ms": createdAtMilliseconds, "is_read": isRead,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, body
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case createdAt = "created_at"
        case createdAtMilliseconds = "created_at_ms"
        case isRead = "is_read"
    }

    private static func bounded(_ value: String, utf8Bytes: Int) -> String {
        var result = String()
        result.reserveCapacity(utf8Bytes)
        var used = 0
        for scalar in value.unicodeScalars {
            let count = scalar.value <= 0x7f ? 1 : scalar.value <= 0x7ff ? 2 : scalar.value <= 0xffff ? 3 : 4
            guard used + count <= utf8Bytes else { break }
            result.unicodeScalars.append(scalar)
            used += count
        }
        return result
    }
}
