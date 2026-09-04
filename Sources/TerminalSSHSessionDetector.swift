import Foundation
import Darwin

struct DetectedSSHSession: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let jumpHost: String?
    let controlPath: String?
    let useIPv4: Bool
    let useIPv6: Bool
    let forwardAgent: Bool
    let compressionEnabled: Bool
    let sshOptions: [String]
    var password: String? = nil

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let session = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[String], Error>
            do {
                let remotePaths = try session.uploadDroppedFilesSync(fileURLs, operation: operation)
                operation.installCancellationCleanupHandler {
                    session.cleanupUploadedRemotePathsAsync(remotePaths)
                }
                do {
                    try operation.throwIfCancelled()
                    result = .success(remotePaths)
                } catch {
                    result = .failure(error)
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                if operation.isCancelled {
                    completion(.failure(TerminalImageTransferExecutionError.cancelled))
                } else {
                    completion(result)
                }
            }
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFiles(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

#if DEBUG
    typealias ProcessOverrideResultForTesting = (
        status: Int32,
        stdout: String,
        stderr: String
    )

    static var runProcessOverrideForTesting: ((
        String,
        [String],
        TimeInterval,
        TerminalImageTransferOperation?
    ) throws -> ProcessOverrideResultForTesting)?

    func uploadDroppedFilesSyncForTesting(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation()
    ) throws -> [String] {
        try uploadDroppedFilesSync(fileURLs, operation: operation)
    }
#endif

    private func uploadDroppedFilesSync(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        let normalizedFilesAndSizes: [(url: URL, size: Int64)] = try fileURLs.map { localURL in
            let normalizedURL = localURL.standardizedFileURL
            guard normalizedURL.isFileURL,
                  let values = try? normalizedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                throw NSError(domain: "cmux.detected-ssh.drop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "detectedSSH.fileDrop.error.notFileURL",
                        defaultValue: "Couldn't upload the dropped item because it isn't a local file. Drop a file from Finder, then try again."
                    ),
                ])
            }
            return (normalizedURL, Int64(max(0, values.fileSize ?? 0)))
        }
        let totalBytes = normalizedFilesAndSizes.reduce(Int64(0)) { partial, file in
            partial + file.size
        }
        operation.beginUpload(totalBytes: totalBytes)

        var uploadedRemotePaths: [String] = []
        var completedBytes: Int64 = 0
        do {
            for file in normalizedFilesAndSizes {
                try operation.throwIfCancelled()
                let remotePath = WorkspaceRemoteSessionController.remoteDropPath(for: file.url)
                // Track the attempted destination before scp starts. If cancellation races
                // process exit, cleanup must also remove a partially written current file.
                uploadedRemotePaths.append(remotePath)

#if DEBUG
                let usesTestProcessOverride = Self.runProcessOverrideForTesting != nil
#else
                let usesTestProcessOverride = false
#endif
                if usesTestProcessOverride {
#if DEBUG
                let (scpExecutable, scpArgs, scpEnvironment) = try wrappedCommand(
                    executable: "/usr/bin/scp",
                        arguments: scpArguments(localPath: file.url.path, remotePath: remotePath)
                )
                let result = try Self.runProcess(
                    executable: scpExecutable,
                    arguments: scpArgs,
                    environment: scpEnvironment,
                    timeout: 45,
                    operation: operation
                )
                guard result.status == 0 else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let base = String(
                        localized: "detectedSSH.fileDrop.error.uploadFailed",
                        defaultValue: "Couldn't upload the file to the remote session. Check that the remote host is reachable, then try again."
                    )
                    throw NSError(domain: "cmux.detected-ssh.drop", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: detail.isEmpty ? base : base + "\n\nscp: " + detail,
                    ])
                }
#endif
                } else {
                    let uploadCommand = WorkspaceRemoteSessionController.remoteDropSCPCommand(
                        for: remotePath
                    )
                    let (sshExecutable, sshArgs, sshEnvironment) = try wrappedCommand(
                        executable: "/usr/bin/ssh",
                        arguments: sshArguments(command: uploadCommand)
                    )
                    let result = try TerminalRemoteFileUploader.upload(
                        localURL: file.url,
                        executable: sshExecutable,
                        arguments: sshArgs,
                        environment: sshEnvironment,
                        timeout: 45,
                        operation: operation,
                        completedBytesBeforeFile: completedBytes,
                        totalBytes: totalBytes,
                        payloadMode: .scp(
                            fileName: (remotePath as NSString).lastPathComponent,
                            fileSize: file.size
                        )
                    )
                    guard result.status == 0 else {
                        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        let base = String(
                            localized: "detectedSSH.fileDrop.error.uploadFailed",
                            defaultValue: "Couldn't upload the file to the remote session. Check that the remote host is reachable, then try again."
                        )
                        throw NSError(domain: "cmux.detected-ssh.drop", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: detail.isEmpty ? base : base + "\n\nssh: " + detail,
                        ])
                    }
                }
                completedBytes += file.size
                operation.reportUploadedBytes(completedBytes, totalBytes: totalBytes)

            }

            return uploadedRemotePaths
        } catch {
            cleanupUploadedRemotePaths(uploadedRemotePaths)
            throw error
        }
    }

    private func scpArguments(localPath: String, remotePath: String) -> [String] {
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
        ]
        if password == nil {
            args += ["-o", "BatchMode=yes"]
        }

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-P", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(Self.scpRemoteDestination(destination)):\(remotePath)"]
        return args
    }

    private func sshArguments(command: String) -> [String] {
        var args: [String] = [
            "-T",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
        ]
        if password == nil {
            args += ["-o", "BatchMode=yes"]
        }

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [destination, command]
        return args
    }

    /// Wraps scp/ssh in sshpass when the session has a password. The password travels in
    /// the `SSHPASS` environment variable (`sshpass -e`), never in argv, where `ps`, Activity
    /// Monitor and crash reports would show it.
    private func wrappedCommand(
        executable: String,
        arguments: [String]
    ) throws -> (String, [String], [String: String]?) {
        guard let password, !password.isEmpty else {
            return (executable, arguments, nil)
        }
        guard let sshpass = Self.sshpassExecutablePath() else {
            throw NSError(domain: "com.unixcision.uniconnect.image-transfer", code: 11, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "terminal.imageTransfer.error.sshpassMissing",
                    defaultValue: "This SSH connection needs sshpass, but UniConnect couldn't find it. Install sshpass and try again."
                ),
            ])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSHPASS"] = password
        return (sshpass, ["-e", executable] + arguments, environment)
    }

    private static let sshpassLookup: String? = {
        // Resolve only explicit, conventional install locations. Running a login shell
        // and trusting `command -v` here would let a project-controlled PATH select a
        // shim from /tmp before a password-bearing upload.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/opt/local/bin/sshpass",
            "\(home)/.local/bin/sshpass",
            "/usr/bin/sshpass",
        ]
        return candidates.first(where: { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: candidate)
        })
    }()

    private static func sshpassExecutablePath() -> String? { sshpassLookup }

    private func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let targets = remotePaths.flatMap { path -> [String] in
            if let directory = WorkspaceRemoteSessionController.remoteDropDirectory(for: path) {
                return [directory, path]
            }
            return path.hasPrefix("/tmp/uniconnect-drop-") ? [path] : []
        }
        guard !targets.isEmpty else { return }
        let cleanupScript = "rm -rf -- " + targets.map(Self.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(Self.shellSingleQuoted(cleanupScript))"
        guard let (sshExecutable, sshArgs, sshEnvironment) = try? wrappedCommand(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(command: cleanupCommand)
        ) else { return }
        _ = try? Self.runProcess(
            executable: sshExecutable,
            arguments: sshArgs,
            environment: sshEnvironment,
            timeout: 8
        )
    }

    private func cleanupUploadedRemotePathsAsync(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let session = self
        DispatchQueue.global(qos: .utility).async {
            session.cleanupUploadedRemotePaths(remotePaths)
        }
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
#if DEBUG
        if let runProcessOverrideForTesting {
            let result = try runProcessOverrideForTesting(executable, arguments, timeout, operation)
            return CommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
        }
#endif

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment { process.environment = environment }

        try operation?.throwIfCancelled()
        try process.run()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        func terminateProcessAndWait() {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            throw NSError(domain: "cmux.detected-ssh.drop", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "detectedSSH.fileDrop.error.scpTimedOut",
                    defaultValue: "File transfer timed out. Check the remote host and network connection, then try again."
                ),
            ])
        }

        let stdout = String(
            data: ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading),
            encoding: .utf8
        ) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6Literal(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func shouldBracketIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

#if DEBUG
    func scpArgumentsForTesting(localPath: String, remotePath: String) -> [String] {
        scpArguments(localPath: localPath, remotePath: remotePath)
    }
#endif
}

enum TerminalSSHSessionDetector {
    struct ProcessSnapshot: Equatable {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String
    }

    static func detectForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundRemoteShellProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let arguments = argumentsByPID[candidate.pid] else { continue }
            if RemoteShellSessionParsing.normalizedExecutableName(candidate.executableName) == "sshpass" {
                if let session = parseSshpassCommandLine(arguments) {
                    return session
                }
                continue
            }
            guard let transport = RemoteShellTransport(executableName: candidate.executableName),
                  let session = parseCommandLine(arguments, for: transport) else {
                continue
            }
            return session
        }

        return nil
    }

    // Sesiones lanzadas via `sshpass -p<pass> ssh ...`: el ssh real corre en un pty
    // interno de sshpass, asi que en el TTY del pane solo se ve `sshpass`. Parseamos su
    // linea de comando para extraer la sesion ssh embebida + el password.
    static func parseSshpassCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }
        var index = 0
        if RemoteShellSessionParsing.normalizedExecutableName(arguments[0]) == "sshpass" {
            index = 1
        }
        var password: String?
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-p") {
                if argument.count > 2 {
                    password = String(argument.dropFirst(2))
                } else {
                    index += 1
                    if index < arguments.count { password = arguments[index] }
                }
                index += 1
            } else if argument == "-f" || argument == "-d" || argument == "-P" {
                index += 2
            } else if argument == "-e" || argument == "-v" {
                index += 1
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                break
            }
        }
        guard index < arguments.count else { return nil }
        let sshArguments = Array(arguments[index...])
        guard var session = parseSSHCommandLine(sshArguments) else { return nil }
        if let password, !password.isEmpty {
            session.password = password
        }
        return session
    }

    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent)
        }
        return trimmed
    }

    private static func isForegroundRemoteShellProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            isRemoteShellExecutable(process.executableName) &&
            process.pgid > 0 &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func isRemoteShellExecutable(_ executableName: String) -> Bool {
        if RemoteShellTransport(executableName: executableName) != nil { return true }
        return RemoteShellSessionParsing.normalizedExecutableName(executableName) == "sshpass"
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(4))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = 4
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            while index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }

        return arguments.count == argc ? arguments : nil
    }

    static func parseCommandLine(
        _ arguments: [String],
        for transport: RemoteShellTransport
    ) -> DetectedSSHSession? {
        switch transport {
        case .ssh:
            return parseSSHCommandLine(arguments)
        case .eternalTerminal:
            return RemoteShellSessionParsing.parseEternalTerminalCommandLine(arguments)
        }
    }

    private static func parseSSHCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if RemoteShellSessionParsing.normalizedExecutableName(arguments[0]) == RemoteShellTransport.ssh.executableName {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var useIPv4 = false
        var useIPv6 = false
        var forwardAgent = false
        var compressionEnabled = false
        var sshOptions: [String] = []

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }

            switch option {
            case "p":
                guard let parsedPort = Int(trimmedValue) else { return false }
                port = parsedPort
                return true
            case "i":
                identityFile = trimmedValue
                return true
            case "F":
                configFile = trimmedValue
                return true
            case "J":
                jumpHost = trimmedValue
                return true
            case "S":
                controlPath = trimmedValue
                return true
            case "l":
                loginName = trimmedValue
                return true
            case "o":
                return RemoteShellSessionParsing.consumeSSHOption(
                    trimmedValue,
                    port: &port,
                    identityFile: &identityFile,
                    controlPath: &controlPath,
                    jumpHost: &jumpHost,
                    loginName: &loginName,
                    sshOptions: &sshOptions
                )
            default:
                return valueArgumentFlags.contains(option)
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                if index < arguments.count {
                    destination = arguments[index]
                }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                destination = argument
                break
            }

            if argument.count > 2,
               let option = argument.dropFirst().first,
               valueArgumentFlags.contains(option) {
                guard consumeValue(String(argument.dropFirst(2)), for: option) else { return nil }
                index += 1
                continue
            }

            if argument.count == 2,
               let optionCharacter = argument.dropFirst().first,
               valueArgumentFlags.contains(optionCharacter) {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeValue(arguments[nextIndex], for: optionCharacter) else {
                    return nil
                }
                index += 2
                continue
            }

            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty, flags.allSatisfy({ noArgumentFlags.contains($0) }) else {
                return nil
            }
            for flag in flags {
                switch flag {
                case "4":
                    useIPv4 = true
                    useIPv6 = false
                case "6":
                    useIPv6 = true
                    useIPv4 = false
                case "A":
                    forwardAgent = true
                case "C":
                    compressionEnabled = true
                default:
                    break
                }
            }
            index += 1
        }

        guard let destination else { return nil }
        let finalDestination = RemoteShellSessionParsing.resolveDestination(destination, loginName: loginName)
        guard !finalDestination.isEmpty else { return nil }

        return DetectedSSHSession(
            destination: finalDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions
        )
    }
}
