import Foundation

/// Value-only item rendered by the expanded sidebar's lazy workspace list.
enum SidebarWorkspaceListItemSnapshot: Equatable, Identifiable {
    case groupHeader(SidebarWorkspaceGroupHeaderSnapshot)
    case workspace(SidebarTabItemSnapshot)

    var id: String {
        switch self {
        case .groupHeader(let snapshot):
            return "group.\(snapshot.groupId.uuidString)"
        case .workspace(let snapshot):
            return "workspace.\(snapshot.workspaceId.uuidString)"
        }
    }
}
