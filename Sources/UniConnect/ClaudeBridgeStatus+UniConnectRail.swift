import SwiftUI
import UniConnectClaudeBridge

extension ClaudeBridgeStatus {
    /// Localized status text shared by the compact tile and its flyout.
    var uniConnectRailLocalizedLabel: String {
        switch self {
        case .inactive:
            return String(localized: "bridge.status.inactive", defaultValue: "Notifications inactive")
        case .reconnecting:
            return String(localized: "bridge.status.reconnecting", defaultValue: "Notifications reconnecting")
        case .active:
            return String(localized: "bridge.status.active", defaultValue: "Notifications active")
        case .unavailable:
            return String(localized: "bridge.status.unavailable", defaultValue: "Notifications unavailable")
        case .error:
            return String(localized: "bridge.status.error", defaultValue: "Notification bridge error")
        }
    }

    /// Semantic status tint shared by the compact tile and its flyout.
    var uniConnectRailTint: Color {
        switch self {
        case .inactive: return .secondary
        case .reconnecting: return .orange
        case .active: return .green
        case .unavailable, .error: return .red
        }
    }
}
