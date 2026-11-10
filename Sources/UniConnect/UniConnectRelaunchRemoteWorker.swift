import CMUXAgentLaunch
import Foundation
import UniConnectClaudeUpdate

/// Runs the Linux relaunch worker on an SSH box, over that box's own pinned SSH invocation.
///
/// One SSH connection per call, bounded to 18 s like on Linux. Nothing about the pane is decided
/// here: the worker proves, closes, reopens and journals on the destination; this only carries the
/// request there and its single `UC_RELAUNCH_V1` line back. The worker also checks the login
/// (`sin_login`) in `inspect` and runs `claude update` for one installation with its `update`
/// action, outside any pane.
actor UniConnectRelaunchRemoteWorker {
    typealias CredentialResolver = @Sendable (UUID) async -> UniConnectSSHCredentialRecord?

    /// What a call produced.
    enum Outcome: Sendable, Equatable {
        /// The worker answered (possibly with its own refusal inside).
        case reply(RelaunchWorkerReply)
        /// The call did not reach the worker, for this reason.
        case unavailable(RelaunchCause)
    }

    private let processRunner: any UniConnectProcessRunning
    private let credentialResolver: CredentialResolver
    private let scripts: @Sendable () -> UniConnectRelaunchWorkerScripts?
    private let ambientEnvironment: @Sendable () -> [String: String]

    init(
        processRunner: any UniConnectProcessRunning,
        credentialResolver: @escaping CredentialResolver,
        scripts: @escaping @Sendable () -> UniConnectRelaunchWorkerScripts? = { UniConnectRelaunchWorkerScripts.bundled() },
        ambientEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.processRunner = processRunner
        self.credentialResolver = credentialResolver
        self.scripts = scripts
        self.ambientEnvironment = ambientEnvironment
    }

    /// The catalogue every request carries, or `nil` when the worker is not bundled.
    func catalogProviders() -> Data? { scripts()?.catalogProviders }

    /// `mensajes.json`, which Claude's `start` carries.
    func messages() -> Data? { scripts()?.messages }

    /// The `ssh:user@host:port` destination of a box, as target keys spell it.
    func destination(credentialID: UUID) async -> RelaunchTargetKey.Destination? {
        guard let target = await credentialResolver(credentialID)?.effectiveTarget else { return nil }
        return .ssh(user: target.user, host: target.host, port: target.port)
    }

    /// Sends one request to the worker on the box of `credentialID`.
    ///
    /// - Parameters:
    ///   - request: The worker request.
    ///   - credentialID: The box's credential.
    /// - Returns: The worker's reply, or why it could not be reached.
    func call(_ request: RelaunchWorkerRequest, credentialID: UUID) async -> Outcome {
        guard let scripts = scripts() else { return .unavailable(.unsupported) }
        guard let command = try? request.remoteCommand(source: scripts.source) else {
            return .unavailable(.unsupported)
        }
        switch await run(command, credentialID: credentialID, timeout: request.timeout) {
        case let .failure(cause):
            return .unavailable(cause)
        case let .success(output):
            guard let reply = RelaunchWorkerReply(output: output) else { return .unavailable(.hostUnreachable) }
            return .reply(reply)
        }
    }

    /// Runs `claude update` once for one installation on the box, through the worker's `update`.
    ///
    /// - Parameters:
    ///   - request: An `update` request naming the installation's `launcher` (and a valid
    ///     session and socket, which every worker call needs).
    ///   - credentialID: The box's credential.
    ///   - host: The installation's host as target keys spell it, for the report.
    /// - Returns: The outcome for `updates[]`; ``RelaunchInstallationUpdate/State/failed`` when the
    ///   worker could not be reached or refused.
    func update(_ request: RelaunchWorkerRequest, credentialID: UUID, host: String) async -> RelaunchInstallationUpdate {
        guard case let .reply(reply) = await call(request, credentialID: credentialID), reply.error == nil else {
            return RelaunchInstallationUpdate(host: host, state: .failed, from: nil, to: nil)
        }
        let fields = reply.fields
        let state = (fields["state"] as? String).flatMap(RelaunchInstallationUpdate.State.init(rawValue:)) ?? .failed
        return RelaunchInstallationUpdate(host: host, state: state, from: fields["from"] as? String, to: fields["to"] as? String)
    }

    /// Decides how an update went from its exit status and the versions before and after.
    nonisolated static func outcome(host: String, status: Int32?, from: ClaudeVersion?, to: ClaudeVersion?) -> RelaunchInstallationUpdate {
        guard let to else {
            return RelaunchInstallationUpdate(host: host, state: .failed, from: from?.description, to: nil)
        }
        if let from, to > from {
            return RelaunchInstallationUpdate(host: host, state: .updated, from: from.description, to: to.description)
        }
        guard status == 0 else {
            return RelaunchInstallationUpdate(host: host, state: .failed, from: from?.description, to: to.description)
        }
        return RelaunchInstallationUpdate(host: host, state: .alreadyCurrent, from: from?.description, to: to.description)
    }

    private func run(_ command: String, credentialID: UUID, timeout: Duration) async -> Result<Data, RelaunchCause> {
        guard let record = await credentialResolver(credentialID),
              let session = UniConnectSSH.detectedSession(fromCredentialRecord: record),
              let invocation = UniConnectSSHProcessInvocation(
                  session: session,
                  remoteCommand: command,
                  ambientEnvironment: ambientEnvironment()
              ) else { return .failure(.noCredential) }
        guard let result = try? await processRunner.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            standardInput: nil,
            timeout: timeout
        ), !result.outputWasTruncated else { return .failure(.hostUnreachable) }
        // 255 is ssh's own failure; the worker always exits 0 after printing its line.
        guard result.terminationStatus != 255 else { return .failure(.hostUnreachable) }
        return .success(result.standardOutput)
    }
}
