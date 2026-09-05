import Foundation

/// Closure-only behavior for one workspace-group header below the lazy-list boundary.
struct SidebarWorkspaceGroupHeaderActions {
    let beginDrag: () -> NSItemProvider
    let drop: SidebarTabItemDropActions
    let toggleCollapsed: () -> Void
    let focusAnchor: () -> Void
    let createWorkspace: () -> Void
    let runResolvedItem: (CmuxResolvedConfigMenuAction) -> Void
    let rename: () -> Void
    let togglePinned: () -> Void
    let ungroup: () -> Void
    let delete: () -> Void
    let editConfig: () -> Void
    let openDocs: () -> Void
}
