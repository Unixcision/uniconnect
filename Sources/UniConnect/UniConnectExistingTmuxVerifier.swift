import Foundation

/// Runs bounded `tmux has-session` checks without creating or attaching sessions.
actor UniConnectExistingTmuxVerifier: UniConnectExistingTmuxVerifying {
    private let executor: any UniConnectSSHCommandExecuting

    init(executor: any UniConnectSSHCommandExecuting) {
        self.executor = executor
    }

    func verify(
        _ requirements: [UniConnectExistingTmuxRequirement]
    ) async -> [UniConnectExistingTmuxVerification] {
        var results: [UniConnectExistingTmuxVerification] = []
        results.reserveCapacity(requirements.count)
        for requirement in requirements {
            let status: UniConnectExistingTmuxVerification.Status
            do {
                try Task.checkCancellation()
                try await executor.execute(requirement.invocation, timeout: .seconds(12))
                status = .available
            } catch {
                status = .unavailable
            }
            results.append(.init(
                workspaceRowID: requirement.workspaceRowID,
                windowID: requirement.windowID,
                session: requirement.session,
                status: status
            ))
        }
        return results
    }
}
