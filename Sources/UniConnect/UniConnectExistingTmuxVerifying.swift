import Foundation

/// Verifies imported tmux declarations using read-only commands only.
protocol UniConnectExistingTmuxVerifying: Sendable {
    func verify(
        _ requirements: [UniConnectExistingTmuxRequirement]
    ) async -> [UniConnectExistingTmuxVerification]
}
