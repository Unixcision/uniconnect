import Darwin
import Foundation

/// Streams one local file to a remote transport with bounded output and process-group ownership.
enum TerminalRemoteFileUploader {
    /// Selects the bytes written to the child process.
    enum PayloadMode: Equatable {
        /// Writes the file bytes without a framing protocol. Used only by isolated tests.
        case raw
        /// Speaks the legacy SCP sink protocol over an SSH standard-input channel.
        case scp(fileName: String, fileSize: Int64)
    }

    struct Result {
        let status: Int32
        let stderr: String
    }

    enum UploadError: LocalizedError, Equatable {
        case timedOut
        case sourceChanged
        case remoteRejected(String)
        case protocolFailed

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return String(
                    localized: "terminal.imageTransfer.error.uploadTimedOut",
                    defaultValue: "File transfer timed out. Check the remote host and network connection, then try again."
                )
            case .sourceChanged:
                return String(
                    localized: "terminal.imageTransfer.error.sourceChanged",
                    defaultValue: "The local file changed while it was being uploaded. Try again."
                )
            case .remoteRejected(let detail):
                return String.localizedStringWithFormat(
                    String(
                        localized: "terminal.imageTransfer.error.remoteRejected",
                        defaultValue: "The remote host rejected the file transfer: %@"
                    ),
                    detail
                )
            case .protocolFailed:
                return String(
                    localized: "terminal.imageTransfer.error.protocolFailed",
                    defaultValue: "The remote host ended the file transfer unexpectedly. Try again."
                )
            }
        }
    }

    private enum StopReason: Equatable {
        case cancelled
        case timedOut
        case transferFailed
    }

    /// Coordinates cancellation with a possibly blocked writer without double-closing descriptors.
    private final class ExecutionState: @unchecked Sendable {
        private let lock = NSLock()
        private var processID: pid_t = -1
        private var stdinWriteFD: Int32 = -1
        private var didFinish = false
        private var stopReason: StopReason?
        private var startedAt = ProcessInfo.processInfo.systemUptime
        private var lastActivityAt = ProcessInfo.processInfo.systemUptime

        func configure(processID: pid_t, stdinWriteFD: Int32) {
            lock.lock()
            self.processID = processID
            self.stdinWriteFD = stdinWriteFD
            startedAt = ProcessInfo.processInfo.systemUptime
            lastActivityAt = startedAt
            lock.unlock()
        }

        func noteActivity() {
            lock.lock()
            if !didFinish {
                lastActivityAt = ProcessInfo.processInfo.systemUptime
            }
            lock.unlock()
        }

        func cancel() {
            requestStop(.cancelled)
        }

        func failTransfer() {
            requestStop(.transferFailed)
        }

        func stopIfTimedOut(inactivityTimeout: TimeInterval, maximumDuration: TimeInterval) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let shouldStop = !didFinish && stopReason == nil && (
                now - lastActivityAt >= inactivityTimeout || now - startedAt >= maximumDuration
            )
            lock.unlock()
            if shouldStop {
                requestStop(.timedOut)
            }
        }

        func closeInputIfOwned(_ fileDescriptor: Int32) {
            lock.lock()
            guard stdinWriteFD == fileDescriptor else {
                lock.unlock()
                return
            }
            stdinWriteFD = -1
            lock.unlock()
            close(fileDescriptor)
        }

        func finishAndTakeReason() -> StopReason? {
            let inputToClose: Int32
            let finalReason: StopReason?
            lock.lock()
            didFinish = true
            finalReason = stopReason
            inputToClose = stdinWriteFD
            stdinWriteFD = -1
            processID = -1
            lock.unlock()
            if inputToClose >= 0 {
                close(inputToClose)
            }
            return finalReason
        }

        private func requestStop(_ reason: StopReason) {
            let pid: pid_t
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            if stopReason == nil || reason == .cancelled {
                stopReason = reason
            }
            pid = processID
            lock.unlock()

            // Do not close the descriptor from a second thread while the writer may
            // be inside `write(2)`: the descriptor number can be recycled before a
            // partial write loops. Killing our private process group closes the pipe's
            // read side and reliably wakes the writer with EPIPE; the writer thread
            // remains the sole owner that closes its descriptor.
            Self.signalProcessGroup(pid, signal: SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.forceKillIfStillOwned(processID: pid)
            }
        }

        private func forceKillIfStillOwned(processID: pid_t) {
            lock.lock()
            let shouldKill = !didFinish && self.processID == processID && stopReason != nil
            lock.unlock()
            if shouldKill {
                Self.signalProcessGroup(processID, signal: SIGKILL)
            }
        }

        static func signalProcessGroup(_ processID: pid_t, signal: Int32) {
            guard processID > 1 else { return }
            if Darwin.kill(-processID, signal) != 0 {
                _ = Darwin.kill(processID, signal)
            }
        }
    }

    private final class BoundedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            let remaining = max(0, maximumBytes - data.count)
            data.append(chunk.prefix(remaining))
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private struct SpawnedProcess {
        let processID: pid_t
        let stdinWriteFD: Int32
        let stdoutReadFD: Int32
        let stderrReadFD: Int32
    }

    static func upload(
        localURL: URL,
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation,
        completedBytesBeforeFile: Int64,
        totalBytes: Int64,
        payloadMode: PayloadMode = .raw
    ) throws -> Result {
        try operation.throwIfCancelled()

        // Open the source before spawning so a local read failure cannot orphan an SSH child.
        let localHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? localHandle.close() }

        let spawned = try spawn(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        let state = ExecutionState()
        state.configure(processID: spawned.processID, stdinWriteFD: spawned.stdinWriteFD)
        operation.installCancellationHandler {
            state.cancel()
        }
        defer { operation.clearCancellationHandler() }

        let inactivityTimeout = max(0.1, timeout)
        let maximumDuration = max(300, inactivityTimeout * 80)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(
            deadline: .now() + min(0.25, inactivityTimeout),
            repeating: min(0.25, inactivityTimeout)
        )
        watchdog.setEventHandler {
            state.stopIfTimedOut(
                inactivityTimeout: inactivityTimeout,
                maximumDuration: maximumDuration
            )
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let stderrBox = BoundedDataBox(maximumBytes: 256 * 1_024)
        let stderrFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            drain(spawned.stderrReadFD, into: stderrBox)
            close(spawned.stderrReadFD)
            stderrFinished.signal()
        }

        let stdoutBox = BoundedDataBox(maximumBytes: 64 * 1_024)
        var rawStdoutFinished: DispatchSemaphore?
        if payloadMode == .raw {
            let finished = DispatchSemaphore(value: 0)
            rawStdoutFinished = finished
            DispatchQueue.global(qos: .utility).async {
                drain(spawned.stdoutReadFD, into: stdoutBox)
                close(spawned.stdoutReadFD)
                finished.signal()
            }
        }

        var transferredBytes: Int64 = 0
        var transferError: Error?
        do {
            switch payloadMode {
            case .raw:
                transferredBytes = try streamRawFile(
                    localHandle,
                    to: spawned.stdinWriteFD,
                    operation: operation,
                    state: state,
                    completedBytesBeforeFile: completedBytesBeforeFile,
                    totalBytes: totalBytes
                )
            case .scp(let fileName, let fileSize):
                transferredBytes = try streamSCPFile(
                    localHandle,
                    fileName: fileName,
                    expectedSize: fileSize,
                    to: spawned.stdinWriteFD,
                    acknowledgementFD: spawned.stdoutReadFD,
                    operation: operation,
                    state: state,
                    completedBytesBeforeFile: completedBytesBeforeFile,
                    totalBytes: totalBytes
                )
            }
        } catch {
            transferError = error
            state.failTransfer()
        }
        state.closeInputIfOwned(spawned.stdinWriteFD)

        let rawStatus = waitForProcess(spawned.processID)
        // Close the watchdog race before waiting for pipe-drain workers. Once the
        // owned child has been reaped, a slow descendant holding stderr open must
        // not retroactively turn a successful transfer into a timeout.
        let stopReason = state.finishAndTakeReason()
        if stopReason != nil {
            // A wrapper such as sshpass may exit before its SSH child. Signal the
            // still-owned group immediately, before waiting on pipe drains and before
            // the numeric process-group id has any opportunity to be reused.
            ExecutionState.signalProcessGroup(spawned.processID, signal: SIGKILL)
        }
        if payloadMode != .raw {
            close(spawned.stdoutReadFD)
        }
        _ = rawStdoutFinished?.wait(timeout: .now() + 1)
        _ = stderrFinished.wait(timeout: .now() + 1)
        if operation.isCancelled || stopReason == .cancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
        if stopReason == .timedOut {
            throw UploadError.timedOut
        }
        if let transferError {
            throw transferError
        }

        let status = normalizedTerminationStatus(rawStatus)
        if status == 0 {
            operation.reportUploadedBytes(
                completedBytesBeforeFile + transferredBytes,
                totalBytes: totalBytes
            )
        }
        return Result(
            status: status,
            stderr: String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
        )
    }

    private static func streamRawFile(
        _ source: FileHandle,
        to destinationFD: Int32,
        operation: TerminalImageTransferOperation,
        state: ExecutionState,
        completedBytesBeforeFile: Int64,
        totalBytes: Int64
    ) throws -> Int64 {
        var transferred: Int64 = 0
        while true {
            try operation.throwIfCancelled()
            guard let chunk = try source.read(upToCount: 128 * 1_024), !chunk.isEmpty else {
                break
            }
            try writeAll(chunk, to: destinationFD, state: state)
            transferred += Int64(chunk.count)
            operation.reportUploadedBytes(completedBytesBeforeFile + transferred, totalBytes: totalBytes)
        }
        if completedBytesBeforeFile + transferred >= totalBytes {
            operation.beginFinalizing()
        }
        return transferred
    }

    private static func streamSCPFile(
        _ source: FileHandle,
        fileName: String,
        expectedSize: Int64,
        to destinationFD: Int32,
        acknowledgementFD: Int32,
        operation: TerminalImageTransferOperation,
        state: ExecutionState,
        completedBytesBeforeFile: Int64,
        totalBytes: Int64
    ) throws -> Int64 {
        let safeName = try validatedSCPFileName(fileName)
        guard expectedSize >= 0 else { throw UploadError.sourceChanged }

        try readSCPAcknowledgement(from: acknowledgementFD, state: state)
        try writeAll(
            Data("C0600 \(expectedSize) \(safeName)\n".utf8),
            to: destinationFD,
            state: state
        )
        try readSCPAcknowledgement(from: acknowledgementFD, state: state)

        var transferred: Int64 = 0
        while transferred < expectedSize {
            try operation.throwIfCancelled()
            let remaining = expectedSize - transferred
            let readSize = Int(min(Int64(128 * 1_024), remaining))
            guard let chunk = try source.read(upToCount: readSize), !chunk.isEmpty else {
                throw UploadError.sourceChanged
            }
            try writeAll(chunk, to: destinationFD, state: state)
            transferred += Int64(chunk.count)
            operation.reportUploadedBytes(completedBytesBeforeFile + transferred, totalBytes: totalBytes)
        }
        if let extra = try source.read(upToCount: 1), !extra.isEmpty {
            throw UploadError.sourceChanged
        }

        if completedBytesBeforeFile + transferred >= totalBytes {
            operation.beginFinalizing()
        }
        try writeAll(Data([0]), to: destinationFD, state: state)
        try readSCPAcknowledgement(from: acknowledgementFD, state: state)
        return transferred
    }

    private static func validatedSCPFileName(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 255,
              !value.contains("/"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("\0") else {
            throw UploadError.protocolFailed
        }
        return value
    }

    private static func readSCPAcknowledgement(
        from fileDescriptor: Int32,
        state: ExecutionState
    ) throws {
        let marker = try readByte(from: fileDescriptor)
        state.noteActivity()
        switch marker {
        case 0:
            return
        case 1, 2:
            var bytes: [UInt8] = []
            bytes.reserveCapacity(256)
            while bytes.count < 16 * 1_024 {
                let byte = try readByte(from: fileDescriptor)
                if byte == 0x0A { break }
                bytes.append(byte)
            }
            let detail = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UploadError.remoteRejected(detail.isEmpty ? "scp" : detail)
        default:
            throw UploadError.protocolFailed
        }
    }

    private static func readByte(from fileDescriptor: Int32) throws -> UInt8 {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count == 1 { return byte }
            if count == 0 { throw UploadError.protocolFailed }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        state: ExecutionState
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if count > 0 {
                    offset += count
                    state.noteActivity()
                    continue
                }
                if count == -1 && errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]?
    ) throws -> SpawnedProcess {
        var stdinFDs = [Int32](repeating: -1, count: 2)
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        defer {
            for fileDescriptor in stdinFDs + stdoutFDs + stderrFDs where fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        try throwIfPOSIXError(pipe(&stdinFDs))
        try throwIfPOSIXError(pipe(&stdoutFDs))
        try throwIfPOSIXError(pipe(&stderrFDs))

        var fileActions: posix_spawn_file_actions_t?
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try throwIfPOSIXError(posix_spawn_file_actions_adddup2(&fileActions, stdinFDs[0], STDIN_FILENO))
        try throwIfPOSIXError(posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO))
        try throwIfPOSIXError(posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO))
        for fileDescriptor in stdinFDs + stdoutFDs + stderrFDs {
            try throwIfPOSIXError(posix_spawn_file_actions_addclose(&fileActions, fileDescriptor))
        }

        var attributes: posix_spawnattr_t?
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try throwIfPOSIXError(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))

        let argv = [executable] + arguments
        let environmentValues = (environment ?? ProcessInfo.processInfo.environment)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(environmentValues) { environmentPointer in
                executable.withCString { executablePointer in
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
        try throwIfPOSIXError(result)

        close(stdinFDs[0])
        stdinFDs[0] = -1
        close(stdoutFDs[1])
        stdoutFDs[1] = -1
        close(stderrFDs[1])
        stderrFDs[1] = -1
        let stdinWriteFD = stdinFDs[1]
        let stdoutReadFD = stdoutFDs[0]
        let stderrReadFD = stderrFDs[0]
        stdinFDs[1] = -1
        stdoutFDs[0] = -1
        stderrFDs[0] = -1
#if os(macOS)
        _ = fcntl(stdinWriteFD, F_SETNOSIGPIPE, 1)
#endif
        return SpawnedProcess(
            processID: processID,
            stdinWriteFD: stdinWriteFD,
            stdoutReadFD: stdoutReadFD,
            stderrReadFD: stderrReadFD
        )
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func throwIfPOSIXError(_ result: Int32) throws {
        guard result != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
    }

    private static func drain(_ fileDescriptor: Int32, into box: BoundedDataBox) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                box.append(Data(buffer.prefix(Int(count))))
                continue
            }
            if count == -1 && errno == EINTR { continue }
            return
        }
    }

    private static func waitForProcess(_ processID: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID { return status }
            if result == -1 && errno == EINTR { continue }
            return status
        }
    }

    private static func normalizedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal != 0 { return 128 + signal }
        return (rawStatus >> 8) & 0xff
    }
}
