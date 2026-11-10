import CMUXAgentLaunch
import Foundation

/// Relaunches one SSH window by handing it to the Linux worker on its box, then reads its journal.
///
/// `start` makes the worker on the destination accept the operation and run it detached from this
/// connection, so a dropped SSH never leaves the pane half-done: the same journal is read again
/// with `status` and no second `start` is ever sent (calcado de `RelaunchAgents.execute`).
struct UniConnectRelaunchRemoteExecutor: Sendable {
    private let worker: UniConnectRelaunchRemoteWorker
    /// How long a target may take on its box before the Mac stops reading its journal.
    ///
    /// The worker's own worst case is about two minutes (60 s clean exit, kill, respawn, 45 s
    /// reopen); past this the target is reported in the state its journal last had.
    private let deadline: Duration
    /// Waits between two journal reads. The destination's journal has no push channel over SSH, so
    /// this bounded, cancellable pause is the intended delay between reads, never a settle.
    private let pause: @Sendable () async -> Void
    private let clock: ContinuousClock

    init(
        worker: UniConnectRelaunchRemoteWorker,
        deadline: Duration = .seconds(180),
        pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(700)) }
    ) {
        self.worker = worker
        self.deadline = deadline
        self.pause = pause
        self.clock = ContinuousClock()
    }

    /// Runs `target` on its box.
    ///
    /// - Parameters:
    ///   - target: The window, with its worker proof.
    ///   - remote: Its SSH route.
    ///   - verb: `agent.relaunch` or `agent.update`.
    ///   - options: `agent.update`'s model and effort.
    ///   - operationID: The operation, which keys the journal on the destination.
    ///   - updatedTo: The version `claude update` left installed (`agent.update`).
    ///   - progress: Told every time the journal shows a new state.
    /// - Returns: Where the target got to.
    func relaunch(
        _ target: UniConnectRelaunchExecutor.Target,
        remote: UniConnectRelaunchRemoteTarget,
        verb: RelaunchVerb,
        options: RelaunchUpdateOptions,
        operationID: UUID,
        updatedTo: String? = nil,
        progress: @escaping @Sendable (RelaunchOperation.Result) async -> Void
    ) async -> RelaunchOperation.Result {
        guard let catalog = await worker.catalogProviders() else {
            return .init(key: target.key, state: .skipped, cause: .unsupported)
        }
        let messages = await worker.messages()
        func request(_ action: RelaunchWorkerRequest.Action) -> RelaunchWorkerRequest {
            RelaunchWorkerRequest(
                action: action, session: remote.session, socket: remote.socket, provider: target.provider,
                windowID: remote.windowID, catalogProviders: catalog,
                verb: action == .status ? nil : verb, expected: remote.proof, operationID: operationID,
                options: action == .status ? nil : options, messages: messages, updatedTo: updatedTo
            )
        }

        var last = RelaunchOperation.Result(key: target.key, state: .planned, provider: target.provider)
        switch await worker.call(request(.start), credentialID: remote.credentialID) {
        case let .unavailable(cause) where cause != .hostUnreachable:
            return .init(key: target.key, state: .skipped, cause: cause)
        case .unavailable:
            // A lost answer is not proof the worker did not accept: read its journal below.
            break
        case let .reply(reply):
            if let refusal = reply.error {
                return Self.refused(target.key, cause: RelaunchCause(rawValue: refusal) ?? .unknownDialog)
            }
            if let progressed = RelaunchWorkerProgress(reply: reply) {
                last = progressed.result(key: target.key, provider: target.provider)
                if progressed.isSettled { return last }
                await progress(last)
            }
        }

        let end = clock.now.advanced(by: deadline)
        while clock.now < end, !Task.isCancelled {
            await pause()
            guard case let .reply(reply) = await worker.call(request(.status), credentialID: remote.credentialID),
                  let progressed = RelaunchWorkerProgress(reply: reply) else { continue }
            let current = progressed.result(key: target.key, provider: target.provider)
            if current != last {
                last = current
                await progress(current)
            }
            if progressed.isSettled { return current }
        }
        return last
    }

    /// The result of a call the worker refused before touching anything.
    private static func refused(_ key: RelaunchTargetKey, cause: RelaunchCause) -> RelaunchOperation.Result {
        switch cause {
        case .unknownDialog, .permissions, .folderTrust, .backgroundTasks:
            .init(key: key, state: .needsUser, cause: cause)
        case .generationChanged, .duplicate:
            .init(key: key, state: .skipped, cause: cause)
        default:
            .init(key: key, state: .failed, cause: cause)
        }
    }
}
