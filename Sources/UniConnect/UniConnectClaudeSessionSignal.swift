import Foundation

/// Immutable local terminal transition used by the updater instead of timer polling.
struct UniConnectClaudeSessionSignal: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case lifecycleChanged
        case shellActivityChanged
        case panelClosed
    }

    let workspaceID: UUID
    let panelID: UUID
    let surfaceGeneration: UUID?
    let kind: Kind
    let lifecycle: String?
    let shellActivity: String?

    init(
        workspaceID: UUID,
        panelID: UUID,
        surfaceGeneration: UUID? = nil,
        kind: Kind,
        lifecycle: String?,
        shellActivity: String?
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.surfaceGeneration = surfaceGeneration
        self.kind = kind
        self.lifecycle = lifecycle
        self.shellActivity = shellActivity
    }
}

extension Notification.Name {
    static let uniConnectClaudeSessionSignal = Notification.Name(
        "com.unixcision.uniconnect.claude-update.session-signal"
    )
}
