import Foundation

/// A source-level fact retained when a declaration cannot become a normal import row.
struct UniConnectImportDiagnostic: Equatable, Hashable, Sendable {
    enum Severity: String, Equatable, Hashable, Sendable {
        case warning
        case error
    }

    enum Code: String, Equatable, Hashable, Sendable {
        case unclosedCodeFence
        case workspaceMissingName
        case conflictingWorkspaceKind
        case malformedTableRow
        case windowMissingIdentity
        case malformedClaudeResume
        case malformedTmuxDeclaration
        case duplicateDeclaration
        case malformedJSONWorkspace
        case malformedJSONWindow
    }

    let severity: Severity
    let code: Code
    let location: UniConnectImportSourceLocation
    /// A password-free label, such as a workspace or window name.
    let subject: String?
}
