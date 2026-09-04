import Darwin
import Foundation

/// Runs bounded child processes without a shell and terminates them on timeout or cancellation.
actor UniConnectControlledProcessRunner: UniConnectProcessRunning {
    private final class ExecutionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var executions: [UUID: Execution] = [:]
        private var isShutDown = false

        func insert(_ execution: Execution, id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isShutDown else { return false }
            executions[id] = execution
            return true
        }

        func remove(id: UUID) {
            lock.lock()
            executions.removeValue(forKey: id)
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            let snapshot = Array(executions.values)
            lock.unlock()
            for execution in snapshot { execution.cancel() }
        }

        func shutdown() {
            lock.lock()
            isShutDown = true
            let snapshot = Array(executions.values)
            lock.unlock()
            for execution in snapshot { execution.cancel() }
        }
    }

    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false

        func launch(_ process: Process) throws {
            lock.lock()
            guard !cancellationRequested else {
                lock.unlock()
                throw UniConnectProcessRunnerError.cancelled
            }
            self.process = process
            do {
                try process.run()
                lock.unlock()
            } catch {
                self.process = nil
                lock.unlock()
                throw UniConnectProcessRunnerError.launchFailed
            }
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            let process = process
            lock.unlock()
            if let process { terminate(process) }
        }

        var wasCancellationRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            let descendants = Self.descendantProcessIDs(of: pid)
            for descendant in descendants.reversed() where descendant > 1 {
                _ = Darwin.kill(descendant, SIGTERM)
            }
            process.terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.forceKillIfStillRunning(pid: pid)
            }
        }

        /// Snapshots the process tree before terminating its root so helpers cannot be orphaned.
        private static func descendantProcessIDs(of root: Int32) -> [Int32] {
            var result: [Int32] = []
            var pending = [root]
            var visited = Set<Int32>()
            while let parent = pending.popLast(), visited.insert(parent).inserted, result.count < 4_096 {
                var children = [pid_t](repeating: 0, count: 256)
                let count = children.withUnsafeMutableBytes { buffer in
                    proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
                }
                guard count > 0 else { continue }
                for child in children.prefix(min(Int(count), children.count)) where child > 1 {
                    result.append(child)
                    pending.append(child)
                }
            }
            return result
        }

        private func forceKillIfStillRunning(pid: Int32) {
            lock.lock()
            let process = self.process
            let isSameProcess = process?.processIdentifier == pid
            let isRunning = process?.isRunning == true
            lock.unlock()
            guard pid > 0, isSameProcess, isRunning else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var stdout = Data()
        private var stderr = Data()
        private var wasTruncated = false
        private var ioFailed = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ data: Data, isStandardError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStandardError {
                let remaining = max(0, maximumBytes - stderr.count)
                stderr.append(data.prefix(remaining))
                wasTruncated = wasTruncated || data.count > remaining
            } else {
                let remaining = max(0, maximumBytes - stdout.count)
                stdout.append(data.prefix(remaining))
                wasTruncated = wasTruncated || data.count > remaining
            }
        }

        func recordIOFailure() {
            lock.lock()
            ioFailed = true
            lock.unlock()
        }

        func snapshot() -> (stdout: Data, stderr: Data, wasTruncated: Bool, ioFailed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (stdout, stderr, wasTruncated, ioFailed)
        }
    }

    private let maximumOutputBytes: Int
    private nonisolated let executionRegistry = ExecutionRegistry()

    init(maximumOutputBytes: Int = 256 * 1_024) {
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    /// Terminates every child owned by this runner, including from app-termination callbacks.
    nonisolated func cancelAll() {
        executionRegistry.cancelAll()
    }

    /// Permanently rejects new children and terminates every child already owned by this runner.
    nonisolated func shutdown() {
        executionRegistry.shutdown()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data? = nil,
        timeout: Duration
    ) async throws -> UniConnectProcessResult {
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              standardInput?.count ?? 0 <= 256 * 1_024,
              timeout > .zero else {
            throw UniConnectProcessRunnerError.invalidRequest
        }

        let execution = Execution()
        let executionID = UUID()
        guard executionRegistry.insert(execution, id: executionID) else {
            throw UniConnectProcessRunnerError.shutDown
        }
        defer { executionRegistry.remove(id: executionID) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: UniConnectProcessResult.self) { group in
                group.addTask { [maximumOutputBytes] in
                    try await Self.execute(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        standardInput: standardInput,
                        maximumOutputBytes: maximumOutputBytes,
                        execution: execution
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw UniConnectProcessRunnerError.timedOut
                }

                do {
                    guard let result = try await group.next() else {
                        throw UniConnectProcessRunnerError.launchFailed
                    }
                    group.cancelAll()
                    guard !execution.wasCancellationRequested else {
                        throw UniConnectProcessRunnerError.cancelled
                    }
                    return result
                } catch {
                    group.cancelAll()
                    execution.cancel()
                    if error is CancellationError { throw UniConnectProcessRunnerError.cancelled }
                    throw error
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private nonisolated static func execute(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        execution: Execution
    ) async throws -> UniConnectProcessResult {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = standardInput == nil ? nil : Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe ?? FileHandle.nullDevice
            try execution.launch(process)

            let outputGroup = DispatchGroup()
            let output = OutputAccumulator(maximumBytes: maximumOutputBytes)

            func beginDrain(_ handle: FileHandle, isStandardError: Bool) {
                outputGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { outputGroup.leave() }
                    do {
                        while let chunk = try handle.read(upToCount: 16 * 1_024), !chunk.isEmpty {
                            output.append(chunk, isStandardError: isStandardError)
                        }
                    } catch {
                        output.recordIOFailure()
                    }
                }
            }

            beginDrain(stdoutPipe.fileHandleForReading, isStandardError: false)
            beginDrain(stderrPipe.fileHandleForReading, isStandardError: true)

            if let standardInput, let stdinPipe {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: standardInput)
                    try stdinPipe.fileHandleForWriting.close()
                } catch {
                    output.recordIOFailure()
                    execution.cancel()
                }
            }

            process.waitUntilExit()
            await withCheckedContinuation { continuation in
                outputGroup.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume()
                }
            }
            if Task.isCancelled || execution.wasCancellationRequested {
                throw UniConnectProcessRunnerError.cancelled
            }
            let captured = output.snapshot()
            if captured.ioFailed { throw UniConnectProcessRunnerError.outputReadFailed }
            return UniConnectProcessResult(
                terminationStatus: process.terminationStatus,
                standardOutput: captured.stdout,
                standardError: captured.stderr,
                outputWasTruncated: captured.wasTruncated
            )
        }.value
    }
}
