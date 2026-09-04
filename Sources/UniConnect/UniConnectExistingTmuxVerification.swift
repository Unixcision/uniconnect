import Foundation

/// The password-free result of checking one declared existing tmux session.
struct UniConnectExistingTmuxVerification: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case available
        case unavailable
    }

    let workspaceRowID: Int
    let windowID: UniConnectImportPlan.WindowID
    let session: String
    let status: Status
}
