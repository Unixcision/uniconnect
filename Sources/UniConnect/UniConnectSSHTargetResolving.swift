/// Resolves SSH destinations in one ordered batch without exposing configuration diagnostics.
protocol UniConnectSSHTargetResolving: Sendable {
    func resolve(
        _ requests: [UniConnectSSHTargetResolutionRequest]
    ) async -> [UniConnectSSHTargetResolutionOutcome]
}

extension UniConnectSSHTargetResolving {
    func resolve(
        _ request: UniConnectSSHTargetResolutionRequest
    ) async -> UniConnectSSHTargetResolutionOutcome {
        let outcomes = await resolve([request])
        return outcomes.first ?? .indeterminate
    }
}
