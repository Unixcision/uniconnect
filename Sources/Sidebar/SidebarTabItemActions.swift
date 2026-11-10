import AppKit
import Foundation

/// Closure action bundle for an expanded-sidebar row below the lazy-list boundary.
struct SidebarTabItemActions {
    /// Every user operation exposed by the row and its context menu.
    enum Action {
        case select(NSEvent.ModifierFlags)
        case close
        case moveBy(Int)
        case rename(String)
        case editSSHConnection
        case applyColor(String?)
        case togglePin
        case createWorkspaceGroup
        case addToWorkspaceGroup(UUID)
        case removeFromWorkspaceGroup
        case newSurface
        case updateClaude
        /// Relanzar las IA de esta caja (`agent.relaunch`), por el mismo camino que el menú Caja.
        case relaunchAgents
        case reconnectSSH
        case moveToTop
        case markRead
        case markUnread
        case closeTargets
        case closeOtherWorkspaces
        case closeBelow
        case closeAbove
        case openPullRequest(URL)
        case openPort(Int)
        case contextMenuDidAppear(SidebarTabItemSnapshot)
        case contextMenuDidDisappear
    }

    let perform: (Action) -> Void
    let beginDrag: () -> NSItemProvider
    let sidebarDrop: SidebarTabItemDropActions
    let bonsplitDrop: SidebarTabItemDropActions
}
