import Foundation

/// Immutable metadata for a window selectable from a compact-rail flyout.
struct UniConnectWindowSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let title: String
    let isFocused: Bool
    let isDisconnected: Bool
    let isUnread: Bool
    let canReconnectSSHNow: Bool
    let requiresLocalRootReassignment: Bool
    let localActionMenu: UniConnectLocalWindowActionMenuSnapshot?

    init(
        id: UUID,
        workspaceID: UUID,
        title: String,
        isFocused: Bool,
        isDisconnected: Bool,
        isUnread: Bool,
        canReconnectSSHNow: Bool = false,
        requiresLocalRootReassignment: Bool = false,
        localActionMenu: UniConnectLocalWindowActionMenuSnapshot? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.isFocused = isFocused
        self.isDisconnected = isDisconnected
        self.isUnread = isUnread
        self.canReconnectSSHNow = canReconnectSSHNow
        self.requiresLocalRootReassignment = requiresLocalRootReassignment
        self.localActionMenu = localActionMenu
    }
}
