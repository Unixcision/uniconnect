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

    var enabledRecoveryActions: [UniConnectLocalWindowActionDescriptor] {
        recoveryActions.filter(\.isEnabled)
    }

    var enabledHistoryActions: [UniConnectLocalWindowActionDescriptor] {
        historyActions.filter(\.isEnabled)
    }

    var enabledAgentActions: [UniConnectLocalWindowActionDescriptor] {
        agentActions.filter(\.isEnabled)
    }

    var enabledForgetActions: [UniConnectLocalWindowActionDescriptor] {
        forgetActions.filter(\.isEnabled)
    }

    var hasEnabledActions: Bool {
        recoveryActions.contains(where: \.isEnabled)
            || historyActions.contains(where: \.isEnabled)
            || agentActions.contains(where: \.isEnabled)
            || forgetActions.contains(where: \.isEnabled)
    }
}
