import Darwin
@preconcurrency import Dispatch
import Foundation

/// Darwin PTY adapter. Commands must already have passed the attach resolver's validation.
actor MobilePTYProcess: MobilePTYRunning {
    private let environment: [String: String]
    private let maximumInputBytes: Int
    private let maximumOutputChunks: Int
    private let chunkBytes = 64 * 1024
    private var started = false
    private var closed = false
    private var childPID: pid_t = 0
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var commandFD: Int32 = -1
    private var pendingInput = Data()
    private var pendingCommand = Data()
    private var output: AsyncStream<MobilePTYOutput>.Continuation?
    private var wakeup: AsyncStream<Void>.Continuation?
    private var pump: Task<Void, Never>?
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var commandWriter: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumInputBytes: Int = 256 * 1024,
        maximumOutputChunks: Int = 64
    ) {
        self.environment = environment
        self.maximumInputBytes = max(1, maximumInputBytes)
        self.maximumOutputChunks = max(1, maximumOutputChunks)
    }

    deinit {
        pump?.cancel()
        wakeup?.finish()
        output?.finish()
        reader?.cancel()
        writer?.cancel()
        commandWriter?.cancel()
        exitSource?.cancel()
        if masterFD >= 0 { Darwin.close(masterFD) }
        if slaveFD >= 0 { Darwin.close(slaveFD) }
        if commandFD >= 0 { Darwin.close(commandFD) }
        if childPID > 0 {
            let pid = childPID
            Darwin.kill(-pid, SIGKILL)
            Darwin.kill(pid, SIGKILL)
            // Reaping an owned, killed child must not block Swift's cooperative executor.
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }

    func start(command: String, columns: Int, rows: Int) throws -> AsyncStream<MobilePTYOutput> {
        guard !closed else { throw MobilePTYProcessError.notRunning }
        guard !started else { throw MobilePTYProcessError.alreadyStarted }
        guard !command.isEmpty, !command.utf8.contains(0), command.utf8.count < chunkBytes else {
            throw MobilePTYProcessError.invalidRequest
        }
        try validateDimensions(columns: columns, rows: rows)
        started = true
        let stream = AsyncStream<MobilePTYOutput>.makeStream(bufferingPolicy: .bufferingNewest(maximumOutputChunks))
        output = stream.continuation
        output?.onTermination = { [weak self] _ in Task { await self?.close() } }
        do {
            try spawn(command: command, columns: columns, rows: rows)
            let readiness = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wakeup = readiness.continuation
            pump = Task { [weak self] in
                for await _ in readiness.stream {
                    guard let self else { break }
                    await self.serviceReady()
                }
            }
            try installSources(readiness.continuation)
            readiness.continuation.yield(())
            return stream.stream
        } catch {
            close()
            throw error
        }
    }

    func write(_ data: Data) throws {
        guard !closed, masterFD >= 0 else { throw MobilePTYProcessError.notRunning }
        guard data.count <= maximumInputBytes - pendingInput.count else {
            fail(.inputOverflow)
            throw MobilePTYProcessError.inputOverflow
        }
        pendingInput.append(data)
        serviceReady()
    }

    func resize(columns: Int, rows: Int) throws {
        guard !closed, masterFD >= 0 else { throw MobilePTYProcessError.notRunning }
        try validateDimensions(columns: columns, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { throw MobilePTYProcessError.system(errno) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        commandWriter?.cancel(); commandWriter = nil
        if masterFD >= 0 { Darwin.close(masterFD); masterFD = -1 }
        if slaveFD >= 0 { Darwin.close(slaveFD); slaveFD = -1 }
        if commandFD >= 0 { Darwin.close(commandFD); commandFD = -1 }
        pendingInput.removeAll()
        pendingCommand.removeAll()
        // The child remains unreaped until serviceReady(), preventing PID reuse here.
        if childPID > 0 {
            Darwin.kill(-childPID, SIGKILL)
            Darwin.kill(childPID, SIGKILL)
        }
        output?.finish(); output = nil
        if childPID == 0 { finishMonitoring() }
    }

    private func fail(_ error: MobilePTYProcessError) {
        // bufferingNewest guarantees that a terminal failure survives a full queue.
        // Dropping bytes is never silent: saturation terminates this attachment.
        output?.yield(.failed(error))
        close()
    }

    private func validateDimensions(columns: Int, rows: Int) throws {
        guard (1...Int(UInt16.max)).contains(columns), (1...Int(UInt16.max)).contains(rows) else {
            throw MobilePTYProcessError.invalidRequest
        }
    }

    private func spawn(command: String, columns: Int, rows: Int) throws {
        masterFD = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard masterFD >= 0 else { throw MobilePTYProcessError.system(errno) }
        guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0, let name = ptsname(masterFD) else {
            throw MobilePTYProcessError.system(errno)
        }
        let slavePath = String(cString: name)
        // Retain a slave until child exit so bootstrap startup cannot look like EOF.
        slaveFD = Darwin.open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slaveFD >= 0 else { throw MobilePTYProcessError.system(errno) }
        try configureNonblocking(masterFD)
        try resize(columns: columns, rows: rows)
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw MobilePTYProcessError.system(errno) }
        defer { descriptors.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        let commandReadFD = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 10)
        guard commandReadFD >= 0 else { throw MobilePTYProcessError.system(errno) }
        defer { Darwin.close(commandReadFD) }
        commandFD = descriptors[1]; descriptors[1] = -1
        try configureNonblocking(commandFD)
        guard fcntl(commandFD, F_SETNOSIGPIPE, 1) == 0 else { throw MobilePTYProcessError.system(errno) }
        pendingCommand = Data((command + "\n").utf8)

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, commandReadFD, 3))
        for descriptor: Int32 in 0...2 {
            try check(posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0))
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var signals = sigset_t()
        sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals))
        sigfillset(&signals)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(bitPattern: UInt16(flags))))
        // Darwin applies SETSID after file actions. Open the slave in the new
        // session's shell to acquire its controlling terminal; never fork Swift.
        let bootstrap = "exec 0<>\"$1\" 1>&0 2>&0; exec /bin/sh /dev/fd/3"
        let arguments = ["/bin/sh", "-c", bootstrap, "uniconnect-mobile-pty", slavePath]
        var childEnvironment = environment
        for key in ["ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "TMUX", "TMUX_PANE"] {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment["TERM"] = "xterm-256color"
        childEnvironment["COLORTERM"] = "truecolor"
        let values = childEnvironment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withStrings(arguments) { argv in
            withStrings(values) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        try check(result)
        childPID = pid
    }

    private func installSources(_ ready: AsyncStream<Void>.Continuation) throws {
        // Darwin has no async-native child-exit notification API.
        let process = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: .global(qos: .utility))
        process.setEventHandler { ready.yield(()) }
        exitSource = process
        process.activate()
        // Dispatch sources expose kernel PTY readiness; the actor owns all I/O and state.
        let readFD = try monitoringDescriptor(masterFD)
        let read = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global(qos: .utility))
        read.setEventHandler { ready.yield(()) }
        read.setCancelHandler { Darwin.close(readFD) }
        reader = read
        read.activate()
    }

    private func makeWriter(_ fd: Int32) throws -> DispatchSourceWrite {
        let monitoredFD = try monitoringDescriptor(fd)
        let source = DispatchSource.makeWriteSource(fileDescriptor: monitoredFD, queue: .global(qos: .utility))
        let ready = wakeup
        source.setEventHandler { ready?.yield(()) }
        source.setCancelHandler { Darwin.close(monitoredFD) }
        source.activate()
        return source
    }

    private func serviceReady() {
        if !closed {
            do {
                try flush(&pendingCommand, to: commandFD)
                if pendingCommand.isEmpty {
                    commandWriter?.cancel(); commandWriter = nil
                    if commandFD >= 0 { Darwin.close(commandFD); commandFD = -1 }
                } else if commandWriter == nil { commandWriter = try makeWriter(commandFD) }
                try flush(&pendingInput, to: masterFD)
                if pendingInput.isEmpty { writer?.cancel(); writer = nil }
                else if writer == nil { writer = try makeWriter(masterFD) }
                drainOutput()
            } catch let error as MobilePTYProcessError { fail(error) }
            catch { fail(.system(EIO)) }
        }
        guard childPID > 0 else { return }
        var status: Int32 = 0
        let result = waitpid(childPID, &status, WNOHANG)
        if result == childPID {
            childPID = 0
            if !closed {
                drainOutput(final: true)
                let signal = status & 0x7f
                let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                if case .dropped = output?.yield(.exited(code)) { fail(.outputOverflow) }
                close()
            }
            finishMonitoring()
        } else if result < 0 && errno == ECHILD {
            childPID = 0
            if !closed { fail(.system(ECHILD)) }
            finishMonitoring()
        }
    }

    private func drainOutput(final: Bool = false) {
        guard !closed, masterFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: chunkBytes)
        for _ in 0..<maximumOutputChunks {
            let count = Darwin.read(masterFD, &bytes, bytes.count)
            if count > 0 {
                switch output?.yield(.bytes(Data(bytes.prefix(count)))) {
                case .enqueued: continue
                case .dropped: fail(.outputOverflow)
                default: close()
                }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EIO { fail(.system(errno)) }
            return
        }
        if final { fail(.outputOverflow) }
        else { wakeup?.yield(()) }
    }

    private func flush(_ data: inout Data, to descriptor: Int32) throws {
        while !data.isEmpty {
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, min($0.count, chunkBytes)) }
            if count > 0 { data.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { throw MobilePTYProcessError.system(count == 0 ? EIO : errno) }
        }
    }

    private func finishMonitoring() {
        exitSource?.cancel(); exitSource = nil
        wakeup?.finish(); wakeup = nil
        pump?.cancel(); pump = nil
    }

    private func configureNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw MobilePTYProcessError.system(errno) }
    }

    private func monitoringDescriptor(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        guard duplicate >= 0 else { throw MobilePTYProcessError.system(errno) }
        return duplicate
    }

    private func check(_ result: Int32) throws {
        if result != 0 { throw MobilePTYProcessError.system(result) }
    }

    private func withStrings<T>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
