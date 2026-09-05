import Foundation

/// Action bundle kept outside ``UniConnectChipSnapshot`` equality.
struct UniConnectChipActions {
    let selectBox: @MainActor () -> Void
    let presentWindowList: @MainActor () -> Void
    let selectWindow: @MainActor (_ workspaceID: UUID, _ panelID: UUID) -> Void
    let performLocalWindowAction: @MainActor (
        _ workspaceID: UUID,
        _ panelID: UUID,
        _ action: UniConnectLocalWindowAction
    ) -> Void
    let reconnectSSHWindowNow: @MainActor (_ workspaceID: UUID, _ panelID: UUID) -> Void
    let renameBox: @MainActor () -> Void
    let editSSHConnection: (@MainActor () -> Void)?
    let setPinned: @MainActor (_ pinned: Bool) -> Void
    let createWindow: @MainActor () -> Void
    let reconnectSSHWindowsNow: @MainActor () -> Void
    let updateClaude: @MainActor () -> Void
    let markRead: @MainActor () -> Void
    let markUnread: @MainActor () -> Void
    let editGroupConfiguration: (@MainActor () -> Void)?
    let ungroup: (@MainActor () -> Void)?
    let closeBox: @MainActor () -> Void
    let toggleGroup: (@MainActor () -> Void)?
}
