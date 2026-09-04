import Darwin
import Foundation

/// Executes bounded, non-interactive SSH maintenance commands with structured cancellation.
actor UniConnectSSHCommandService: UniConnectSSHCommandExecuting {
    enum ExecutionError: Error, Sendable {
        case launch
        case timedOut
        case failed(Int32)
    }

    private final class ProcessGroupBox: @unchecked Sendable {
        private let lock = NSLock()
        private var processID: pid_t = -1
        private var cancellationRequested = false
        private var didFinish = false

        func register(processID: pid_t) -> Bool {
            lock.lock()
            self.processID = processID
            let shouldTerminate = cancellationRequested
            lock.unlock()
            if shouldTerminate {
                requestTermination()
            }
            return !shouldTerminate
        }

        func markFinished(processID: pid_t) {
            lock.lock()
            if self.processID == processID {
                self.processID = -1
                didFinish = true
            }
            lock.unlock()
        }

        func requestTermination() {
            lock.lock()
            cancellationRequested = true
            let processID = self.processID
            let shouldSignal = !didFinish && processID > 1
            lock.unlock()
            guard shouldSignal else { return }

            Self.signalProcessGroup(processID, signal: SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.forceKillIfStillOwned(processID: processID)
            }
        }

        private func forceKillIfStillOwned(processID: pid_t) {
            lock.lock()
            let shouldKill = !didFinish && self.processID == processID && cancellationRequested
            lock.unlock()
            if shouldKill {
                Self.signalProcessGroup(processID, signal: SIGKILL)
            }
        }

        private static func signalProcessGroup(_ processID: pid_t, signal: Int32) {
            guard processID > 1 else { return }
            if Darwin.kill(-processID, signal) != 0 {
                _ = Darwin.kill(processID, signal)
            }
        }
    }

    func execute(
        _ invocation: UniConnectSSHProcessInvocation,
        timeout: Duration = .seconds(12)
    ) async throws {
        enum Outcome: Sendable {
            case exited(Int32)
            case timeout
            case cancelled
            case launchFailed
        }

        let processGroup = ProcessGroupBox()
        let outcome = await withTaskCancellationHandler {
            let processID: pid_t
            do {
                processID = try Self.spawn(invocation)
            } catch {
                return Outcome.launchFailed
            }
            let accepted = processGroup.register(processID: processID)
            return await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    let status = await Task.detached(priority: .utility) {
                        Self.waitForProcess(processID)
                    }.value
                    processGroup.markFinished(processID: processID)
                    return .exited(status)
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timeout
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .launchFailed
                switch first {
                case .timeout, .cancelled:
                    processGroup.requestTermination()
                case .exited, .launchFailed:
                    break
                }
                group.cancelAll()
                return accepted ? first : .cancelled
            }
        } onCancel: {
            processGroup.requestTermination()
        }

        switch outcome {
        case .exited(0):
            return
        case .exited(let status):
            throw ExecutionError.failed(status)
        case .timeout:
            throw ExecutionError.timedOut
        case .cancelled:
            throw CancellationError()
        case .launchFailed:
            throw ExecutionError.launch
        }
    }

    private nonisolated static func spawn(
        _ invocation: UniConnectSSHProcessInvocation
    ) throws -> pid_t {
        guard invocation.executable.hasPrefix("/"),
              !invocation.executable.contains("\0"),
              invocation.arguments.allSatisfy({ !$0.contains("\0") }),
              invocation.environment.allSatisfy({
                  !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0")
              }) else {
            throw ExecutionError.launch
        }

        let nullDescriptor = Darwin.open("/dev/null", O_RDWR)
        guard nullDescriptor >= 0 else { throw ExecutionError.launch }
        defer { Darwin.close(nullDescriptor) }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ExecutionError.launch
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_adddup2(&fileActions, nullDescriptor, descriptor) == 0 else {
                throw ExecutionError.launch
            }
        }
        guard posix_spawn_file_actions_addclose(&fileActions, nullDescriptor) == 0 else {
            throw ExecutionError.launch
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ExecutionError.launch
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw ExecutionError.launch
        }

        let argv = [invocation.executable] + invocation.arguments
        let environment = invocation.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(environment) { environmentPointer in
                invocation.executable.withCString { executablePointer in
                    posix_spawn(
                        &processID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard result == 0, processID > 1 else { throw ExecutionError.launch }
        return processID
    }

    private nonisolated static func waitForProcess(_ processID: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID { return normalizedTerminationStatus(status) }
            if result == -1 && errno == EINTR { continue }
            return -1
        }
    }

    private nonisolated static func normalizedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal != 0 { return 128 + signal }
        return (rawStatus >> 8) & 0xff
    }

    private nonisolated static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
