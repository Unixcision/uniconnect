import Foundation

/// A read-only remote check required before attaching to a declared existing tmux session.
struct UniConnectExistingTmuxRequirement: Sendable {
    let workspaceRowID: Int
    let windowID: UniConnectImportPlan.WindowID
    let session: String
    let invocation: UniConnectSSHProcessInvocation
}
