import Darwin
import Dispatch
import Foundation

/// Uses a Darwin process dispatch source to await exact PID termination.
actor UniConnectLocalProcessExitWaiter: UniConnectProcessExitWaiting {
    enum WaitError: Error, Sendable, Equatable {
        case invalidProcessID
        case timedOut
    }

    private final class SourceBox: @unchecked Sendable {
        let source: DispatchSourceProcess

        init(source: DispatchSourceProcess) {
            self.source = source
        }

        func cancel() {
            source.cancel()
        }
    }

    func waitForExit(processID: Int32, timeout: Duration) async throws {
        guard processID > 1 else { throw WaitError.invalidProcessID }
        if kill(processID, 0) == -1, errno == ESRCH { return }

        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(processID),
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let sourceBox = SourceBox(source: source)
        source.setEventHandler {
            pair.continuation.yield(())
            pair.continuation.finish()
        }
        source.setCancelHandler {
            pair.continuation.finish()
        }
        source.activate()

        if kill(processID, 0) == -1, errno == ESRCH {
            sourceBox.cancel()
            return
        }

        enum Outcome: Sendable {
            case exited
            case timedOut
        }
        let outcome = await withTaskCancellationHandler {
            await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    var iterator = pair.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    return .exited
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    } catch {
                        return .exited
                    }
                }
                let first = await group.next() ?? .timedOut
                group.cancelAll()
                return first
            }
        } onCancel: {
            sourceBox.cancel()
        }
        sourceBox.cancel()
        try Task.checkCancellation()
        guard case .exited = outcome else { throw WaitError.timedOut }
    }
}
