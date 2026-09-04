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
        case invalidLocalWorkingDirectory
        case sshWindowMissingTmux
        case sshWindowHasClaudeSession
        case invalidClaudeSession
        case invalidTmuxSession
        case emptyGroupName
        case pinnedWorkspaceHasGroup
        case duplicateWorkspaceIdentifier(UUID)
        case duplicateWorkspaceName
        case duplicateClaudeSession(UUID)
        case duplicateAgentSession(kind: RestorableAgentKind, sessionID: String)
        case duplicateTmuxTarget(host: String, session: String)
        case ambiguousStableIdentity
        case ambiguousName
        case workspaceKindMismatch
        case activeAgentWouldBeReplaced
        case sourceDiagnostic(code: UniConnectImportDiagnostic.Code, line: Int)
    }

    /// A password-free summary safe to pass to the preview UI.
    struct WorkspacePreview: Equatable, Sendable {
        let name: String
        let kind: UniConnectWorkspaceKind
        let color: String?
        let group: String?
        let cwd: String?
        let hostLabel: String?
        let declaredWindowCount: Int
    }

    /// Stable source identity for a window declaration.
    struct WindowID: Equatable, Hashable, Sendable {
        let workspaceIndex: Int
        let windowIndex: Int
    }

    /// The password-free destination used when creating or updating a window.
    enum WindowDestination: Equatable, Sendable {
        case terminal
        case agent(kind: RestorableAgentKind, sessionID: String)
        case attachExistingTmux(session: String)
        case createTmuxIfMissing(session: String)
    }

    /// The concrete, password-free action shown for one imported window.
    enum WindowAction: Equatable, Sendable {
        case create(WindowDestination)
        case update(WindowDestination)
        case leaveUnchanged
        case keepTerminalBecauseDuplicateAgent(
            kind: RestorableAgentKind,
            sessionID: String,
            mutation: Outcome
        )
        case reject
    }

    /// One source window and its exact reconciliation result.
    struct WindowRow: Identifiable, Equatable {
        let id: WindowID
        let name: String
        let outcome: Outcome
        let action: WindowAction
        /// Index in the matched workspace snapshot, or nil when the declaration creates a window.
        let existingWindowIndex: Int?
        let issues: [Issue]
        let sourceLocation: UniConnectImportSourceLocation?
        let tmuxPolicy: UniConnectTmuxImportPolicy

        /// Duplicate agent bindings are resolved safely by leaving the later window as a shell.
        var isResolvedConflict: Bool {
            if case .keepTerminalBecauseDuplicateAgent = action { return true }
            return false
        }

        var requiresMutation: Bool {
            switch action {
            case .create, .update:
                return true
            case .keepTerminalBecauseDuplicateAgent(_, _, let mutation):
                return mutation.isMutation
            case .leaveUnchanged, .reject:
                return false
            }
        }
    }

    /// One source workspace and the deterministic result of reconciling it.
    struct Row: Identifiable, Equatable {
        var id: Int { sourceIndex }

        let sourceIndex: Int
        // Transitional payload access for the current executor. The preview must use
        // `preview`, which never contains the connection command.
        let workspace: UniConnectDocument.Workspace
        let preview: WorkspacePreview
        let existingWorkspaceIndex: Int?
        let existingWorkspaceID: UUID?
        let outcome: Outcome
        let issues: [Issue]
        let windowRows: [WindowRow]
        let sourceLocation: UniConnectImportSourceLocation?

        init(
            sourceIndex: Int,
            workspace: UniConnectDocument.Workspace,
            preview: WorkspacePreview? = nil,
            existingWorkspaceIndex: Int? = nil,
            existingWorkspaceID: UUID?,
            outcome: Outcome,
            issues: [Issue],
            windowRows: [WindowRow] = [],
            sourceLocation: UniConnectImportSourceLocation? = nil
        ) {
            self.sourceIndex = sourceIndex
            self.workspace = workspace
            self.preview = preview ?? WorkspacePreview(
                name: workspace.name,
                kind: workspace.kind,
                color: workspace.color,
                group: workspace.group,
                cwd: workspace.kind == .local ? workspace.cwd : nil,
                hostLabel: nil,
                declaredWindowCount: workspace.windows.count
            )
            self.existingWorkspaceIndex = existingWorkspaceIndex
            self.existingWorkspaceID = existingWorkspaceID
            self.outcome = outcome
            self.issues = issues
            self.windowRows = windowRows
            self.sourceLocation = sourceLocation
        }

        var isSelectable: Bool { outcome.isMutation }
    }

    let rows: [Row]
    /// Source errors that could not be assigned to a specific workspace declaration.
    let documentIssues: [Issue]

    init(rows: [Row], documentIssues: [Issue] = []) {
        self.rows = rows
        self.documentIssues = documentIssues
    }

    /// Whether a source workspace cannot be applied safely.
    var hasBlockingIssues: Bool {
        !documentIssues.isEmpty || rows.contains(where: { $0.outcome.isBlocking })
    }

    /// Updates need a transactional live-state reconciler rather than the create-only executor.
    var requiresTransactionalUpdates: Bool { rows.contains(where: { $0.outcome == .update }) }

    /// Whether the existing executor can safely receive only fully planned create rows.
    var canUseCreateOnlyExecutor: Bool { !hasBlockingIssues && !requiresTransactionalUpdates }

    /// Rows the existing create-only executor may apply after the plan passes its gate.
    var createRows: [Row] { rows.filter { $0.outcome == .create } }

    /// Create and update rows eligible for an explicit import selection.
    var mutationRows: [Row] { rows.filter(\.isSelectable) }

    /// Default selection includes every safe mutation and excludes unchanged/blocked rows.
    var defaultSelectedRowIDs: Set<Int> { Set(mutationRows.map(\.id)) }
}
