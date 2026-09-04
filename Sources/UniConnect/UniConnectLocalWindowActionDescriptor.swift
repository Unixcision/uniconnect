import Foundation

/// Immutable presentation metadata for one local-window action.
struct UniConnectLocalWindowActionDescriptor: Equatable, Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case standard
        case destructive
    }

    let action: UniConnectLocalWindowAction
    let title: String
    let subtitle: String?
    let systemImageName: String
    let role: Role
    let isEnabled: Bool

    var id: String { action.id }
}
