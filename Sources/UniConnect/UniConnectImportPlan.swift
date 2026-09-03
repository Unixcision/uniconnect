import Foundation

/// A deterministic, side-effect-free reconciliation plan for one imported document.
struct UniConnectImportPlan: Equatable {
    /// The action or blocking state assigned to one source workspace row.
    enum Outcome: String, Equatable, Sendable {
        case create
        case update
        case unchanged
        case conflict
        case rejected

        var isBlocking: Bool { self == .conflict || self == .rejected }
        var isMutation: Bool { self == .create || self == .update }
    }

    /// A validation or matching fact that explains a row's outcome.
    enum Issue: Equatable, Hashable, Sendable {
        case emptyWorkspaceName
        case missingSSHConnection
        case invalidSSHConnection
        case unexpectedSSHConnection
        case localWorkspaceMissingWindow
        case localWindowHasTmux
        case sshWindowMissingTmux
        case sshWindowHasClaudeSession
        case invalidClaudeSession
        case invalidTmuxSession
        case emptyGroupName
        case pinnedWorkspaceHasGroup
        case duplicateWorkspaceIdentifier(UUID)
        case duplicateWorkspaceName
        case duplicateClaudeSession(UUID)
        case duplicateTmuxTarget(host: String, session: String)
        case ambiguousStableIdentity
        case ambiguousName
        case workspaceKindMismatch
    }

    /// One source workspace and the deterministic result of reconciling it.
    struct Row: Identifiable, Equatable {
        var id: Int { sourceIndex }

        let sourceIndex: Int
        let workspace: UniConnectDocument.Workspace
        let existingWorkspaceID: UUID?
        let outcome: Outcome
        let issues: [Issue]
    }

    let rows: [Row]

    /// Whether any source row must block the entire document before mutation begins.
    var hasBlockingIssues: Bool { rows.contains(where: { $0.outcome.isBlocking }) }

    /// Updates need a transactional live-state reconciler rather than the create-only executor.
    var requiresTransactionalUpdates: Bool { rows.contains(where: { $0.outcome == .update }) }

    /// Whether the existing executor can safely receive only fully planned create rows.
    var canUseCreateOnlyExecutor: Bool { !hasBlockingIssues && !requiresTransactionalUpdates }

    /// Rows the existing create-only executor may apply after the plan passes its gate.
    var createRows: [Row] { rows.filter { $0.outcome == .create } }
}
