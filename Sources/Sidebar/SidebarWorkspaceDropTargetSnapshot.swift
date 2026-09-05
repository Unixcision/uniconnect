import Foundation

/// Immutable workspace identity and pin state used to resolve sidebar drop targets.
struct SidebarWorkspaceDropTargetSnapshot: Equatable {
    let workspaceId: UUID
    let isPinned: Bool
}
