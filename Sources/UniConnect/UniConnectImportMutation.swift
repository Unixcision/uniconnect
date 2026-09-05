import Foundation

/// One in-memory workspace mutation; connection secrets must never be logged or journaled.
struct UniConnectImportMutation: Equatable {
    let rowID: Int
    let outcome: UniConnectImportPlan.Outcome
    let existingWorkspaceIndex: Int?
    let existingWorkspaceID: UUID?
    let workspace: UniConnectDocument.Workspace
    let windowRows: [UniConnectImportPlan.WindowRow]
    /// Exact encrypted-vault payload for an SSH row, including its captured endpoint.
    let sshCredentialRecord: UniConnectSSHCredentialRecord?

    init(
        rowID: Int,
        outcome: UniConnectImportPlan.Outcome,
        existingWorkspaceIndex: Int?,
        existingWorkspaceID: UUID?,
        workspace: UniConnectDocument.Workspace,
        windowRows: [UniConnectImportPlan.WindowRow],
        sshCredentialRecord: UniConnectSSHCredentialRecord? = nil
    ) {
        self.rowID = rowID
        self.outcome = outcome
        self.existingWorkspaceIndex = existingWorkspaceIndex
        self.existingWorkspaceID = existingWorkspaceID
        self.workspace = workspace
        self.windowRows = windowRows
        self.sshCredentialRecord = sshCredentialRecord
    }
}
