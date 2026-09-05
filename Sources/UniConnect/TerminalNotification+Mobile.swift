import CMUXMobileCore
import Foundation

extension TerminalNotification {
    /// Both list replay and live creation serialize this exact retained identity.
    var mobileNotificationRecord: MobileNotificationRecord {
        MobileNotificationRecord(
            id: id.uuidString,
            workspaceID: tabId.uuidString,
            surfaceID: (panelId ?? surfaceId)?.uuidString,
            title: title, subtitle: subtitle, body: body,
            createdAtMilliseconds: Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down)),
            isRead: isRead
        )
    }
}
