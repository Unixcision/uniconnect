import Foundation

/// A value-only menu projection that every local-window entry point can render safely.
struct UniConnectLocalWindowActionMenuSnapshot: Equatable, Sendable {
    let windowID: UUID
    let runtimeTitle: String
    let runtimeDetail: String
    let recoveryActions: [UniConnectLocalWindowActionDescriptor]
    let historyActions: [UniConnectLocalWindowActionDescriptor]
    let agentActions: [UniConnectLocalWindowActionDescriptor]
    let forgetActions: [UniConnectLocalWindowActionDescriptor]

    var preferredRecoveryAction: UniConnectLocalWindowActionDescriptor? {
        recoveryActions.first(where: \.isEnabled)
    }
}
