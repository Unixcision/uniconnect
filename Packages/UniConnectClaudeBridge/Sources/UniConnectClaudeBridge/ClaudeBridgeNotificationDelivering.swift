import Foundation

/// Delivers an authenticated user-visible completion into the app's notification domain.
@MainActor
public protocol ClaudeBridgeNotificationDelivering: Sendable {
    /// Adds one privacy-minimized notification for an exact workspace and surface.
    ///
    /// - Parameters:
    ///   - event: Authenticated remote `Stop` or `idle_prompt` event.
    ///   - route: Trusted local routing metadata; remote metadata is never used for navigation.
    func deliver(event: ClaudeBridgeEvent, route: ClaudeBridgeRoute)
}
