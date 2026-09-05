import Foundation

/// The app's current ownership of one durable local terminal, captured before socket authorization.
struct UniConnectLocalTmuxOwner: Equatable, Sendable {
    let workspaceID: UUID
    let panelID: UUID
    let binding: UniConnectLocalTmuxBinding
    let surfaceGeneration: UUID
}
