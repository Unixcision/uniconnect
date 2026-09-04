import Foundation

/// One in-memory workspace mutation; connection secrets must never be logged or journaled.
struct UniConnectImportMutation: Equatable {
    let rowID: Int
    let outcome: UniConnectImportPlan.Outcome
    let existingWorkspaceIndex: Int?
    let existingWorkspaceID: UUID?
    let workspace: UniConnectDocument.Workspace
    let windowRows: [UniConnectImportPlan.WindowRow]
}
