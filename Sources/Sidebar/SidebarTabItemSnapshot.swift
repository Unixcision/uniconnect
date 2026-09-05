import CoreGraphics
import Foundation

/// Immutable rendering and menu state for one expanded-sidebar workspace row.
struct SidebarTabItemSnapshot: Equatable {
    /// Parent-owned context-menu lifecycle state for one frozen row snapshot.
    ///
    /// The expanded sidebar resolves this state before its `LazyVStack`, so a
    /// live workspace/notification update cannot invalidate the row underneath
    /// an open AppKit context menu. Dismissing the menu releases the captured
    /// value and lets the next parent projection render the latest snapshot.
    struct ContextMenuFreezeState: Equatable {
        private(set) var frozenSnapshot: SidebarTabItemSnapshot?

        init() {}

        var frozenWorkspaceId: UUID? {
            frozenSnapshot?.workspaceId
        }

        mutating func contextMenuDidAppear(with snapshot: SidebarTabItemSnapshot) {
            if frozenSnapshot?.workspaceId == snapshot.workspaceId {
                return
            }
            frozenSnapshot = snapshot
        }

        mutating func contextMenuDidDisappear(for workspaceId: UUID) {
            guard frozenSnapshot?.workspaceId == workspaceId else { return }
            frozenSnapshot = nil
        }

        mutating func retainAvailableWorkspaces(_ workspaceIds: Set<UUID>) {
            guard let frozenWorkspaceId, !workspaceIds.contains(frozenWorkspaceId) else { return }
            frozenSnapshot = nil
        }

        func resolving(_ liveSnapshot: SidebarTabItemSnapshot) -> SidebarTabItemSnapshot {
            guard frozenSnapshot?.workspaceId == liveSnapshot.workspaceId else {
                return liveSnapshot
            }
            return frozenSnapshot ?? liveSnapshot
        }
    }

    /// Immutable context-menu state projected above the lazy-list boundary.
    struct ContextMenu: Equatable {
        let targetWorkspaceIds: [UUID]
        let shouldPin: Bool
        let canTogglePin: Bool
        let isSSHWorkspace: Bool
        let hasCustomColor: Bool
        let customColorSeed: String?
        let canReconnectSSH: Bool
        let canMarkRead: Bool
        let canMarkUnread: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool
        let canMoveToTop: Bool
        let canCloseTargets: Bool
        let canCloseOtherWorkspaces: Bool
        let canCloseBelow: Bool
        let canCloseAbove: Bool
        let eligibleForGrouping: Bool
        let allEligibleTargetsGroupId: UUID?
        let hasAnyGroupedEligibleTarget: Bool
        let groupMenu: WorkspaceGroupMenuSnapshot

        var isMultiSelection: Bool {
            targetWorkspaceIds.count > 1
        }
    }

    let workspaceId: UUID
    let workspace: SidebarWorkspaceSnapshotBuilder.Snapshot
    let customTitle: String?
    let isGroupMember: Bool
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let isMultiSelected: Bool
    let showsModifierShortcutHints: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let finderDirectoryPath: String?
    let contextMenu: ContextMenu
    let settings: SidebarTabItemSettingsSnapshot
}
