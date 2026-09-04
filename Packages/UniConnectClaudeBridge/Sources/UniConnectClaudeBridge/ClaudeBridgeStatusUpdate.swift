import Foundation

/// A route-scoped status update consumed by the app's immutable sidebar snapshots.
public struct ClaudeBridgeStatusUpdate: Sendable, Equatable {
    /// The route whose status changed.
    public let routeID: UUID

    /// The new route status.
    public let status: ClaudeBridgeStatus

    /// Creates a status update.
    ///
    /// - Parameters:
    ///   - routeID: Stable bridge route UUID.
    ///   - status: New route status.
    public init(routeID: UUID, status: ClaudeBridgeStatus) {
        self.routeID = routeID
        self.status = status
    }
}
