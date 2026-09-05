import Foundation

/// Resolves one manual SSH connection before any workspace or vault mutation is allowed.
@MainActor
struct UniConnectSSHWorkspaceCreationTransaction {
    enum Failure: Error, Equatable {
        case invalidConnection
        case staleSubmission
        case cancelled
    }

    typealias CurrentSubmissionCheck = @MainActor () -> Bool

    private let targetResolver: any UniConnectSSHTargetResolving

    init(targetResolver: any UniConnectSSHTargetResolving) {
        self.targetResolver = targetResolver
    }

    /// Returns a complete record only while the original submission still owns the flow.
    func prepare(
        connectCommand: String,
        isCurrentSubmission: CurrentSubmissionCheck
    ) async throws -> UniConnectSSHCredentialRecord {
        guard isCurrentSubmission() else { throw Failure.staleSubmission }
        guard let validated = UniConnectSSHConnectCommandValidator()
            .validatedCommand(connectCommand),
              let request = validated.targetResolutionRequest() else {
            throw Failure.invalidConnection
        }

        guard !Task.isCancelled else { throw Failure.cancelled }
        let outcome = await targetResolver.resolve(request)
        guard !Task.isCancelled else { throw Failure.cancelled }
        guard isCurrentSubmission() else { throw Failure.staleSubmission }
        guard case .resolved(let effectiveTarget) = outcome else {
            throw Failure.invalidConnection
        }
        return UniConnectSSHCredentialRecord(
            connectCommand: connectCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            effectiveTarget: effectiveTarget
        )
    }
}
