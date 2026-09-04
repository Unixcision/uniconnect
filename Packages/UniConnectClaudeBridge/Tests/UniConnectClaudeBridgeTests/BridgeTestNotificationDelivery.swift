import Foundation
@testable import UniConnectClaudeBridge

@MainActor
final class BridgeTestNotificationDelivery: ClaudeBridgeNotificationDelivering {
    private(set) var deliveries: [(ClaudeBridgeEvent, ClaudeBridgeRoute)] = []

    func deliver(event: ClaudeBridgeEvent, route: ClaudeBridgeRoute) {
        deliveries.append((event, route))
    }
}
