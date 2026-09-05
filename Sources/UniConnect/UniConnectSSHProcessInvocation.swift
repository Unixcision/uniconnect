import Foundation

/// A shell-free SSH subprocess request whose optional password exists only in its environment.
struct UniConnectSSHProcessInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]

    /// Builds a validated shell-free process request for internal maintenance helpers.
    init?(executable: String, arguments: [String], environment: [String: String]) {
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({
                  !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0")
              }) else {
            return nil
        }
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    init?(
        session: DetectedSSHSession,
        remoteCommand: String,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        sshpassPathResolver: ((FileManager) -> String?)? = nil
    ) {
        guard Self.isSafeDestination(session.destination),
              !remoteCommand.isEmpty,
              !remoteCommand.contains("\0") else {
            return nil
        }

        var sshArguments = session.uniConnectEffectiveTarget?.sshPinningOptions ?? []
        sshArguments += [
            "-T",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "PermitLocalCommand=no",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if session.password == nil {
            sshArguments += ["-o", "BatchMode=yes"]
        } else {
            sshArguments += ["-o", "BatchMode=no"]
        }
        if session.useIPv4 {
            sshArguments.append("-4")
        } else if session.useIPv6 {
            sshArguments.append("-6")
        }
        if session.compressionEnabled { sshArguments.append("-C") }
        if let configFile = Self.nonEmpty(session.configFile) {
            sshArguments += ["-F", configFile]
        }
        if let jumpHost = Self.nonEmpty(session.jumpHost) {
            sshArguments += ["-J", jumpHost]
        }
        if let port = session.port, (1...65_535).contains(port) {
            sshArguments += ["-p", String(port)]
        }
        if let identityFile = Self.nonEmpty(session.identityFile) {
            sshArguments += ["-i", identityFile]
        }
        if !Self.containsOption(session.sshOptions, named: "StrictHostKeyChecking") {
            sshArguments += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in session.sshOptions where Self.isCompatibleAdditionalOption(option) {
            sshArguments += ["-o", option]
        }
        sshArguments += [session.destination, remoteCommand]

        var environment = Self.minimumEnvironment(from: ambientEnvironment)
        if let password = Self.nonEmpty(session.password) {
            let sshpass: String?
            if let sshpassPathResolver {
                sshpass = sshpassPathResolver(fileManager)
            } else {
                sshpass = Self.sshpassPath(fileManager: fileManager)
            }
            guard let sshpass else {
                return nil
            }
            environment["SSHPASS"] = password
            executable = sshpass
            arguments = ["-e", "/usr/bin/ssh"] + sshArguments
        } else {
            executable = "/usr/bin/ssh"
            arguments = sshArguments
        }
        self.environment = environment
    }

    private static func minimumEnvironment(from ambient: [String: String]) -> [String: String] {
        let directKeys = [
            "HOME", "USER", "LOGNAME", "TMPDIR",
            "LANG", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        ]
        var result: [String: String] = [:]
        for key in directKeys {
            if let value = ambient[key], !value.contains("\0") { result[key] = value }
        }
        for (key, value) in ambient where key.hasPrefix("LC_") && !value.contains("\0") {
            result[key] = value
        }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // `ssh -J` spawns a nested ssh through PATH. Never inherit a directory that could
        // contain an attacker-controlled executable from the app or imported environment.
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["TERM"] = "dumb"
        return result
    }

    private static func sshpassPath(fileManager: FileManager) -> String? {
        UniConnectSSHConnectCommandValidator.trustedSSHpassExecutable {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private static func isSafeDestination(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              !trimmed.contains("\0") else {
            return false
        }
        return !trimmed.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func containsOption(_ options: [String], named expectedKey: String) -> Bool {
        let expected = expectedKey.lowercased()
        return options.contains { optionKey($0) == expected }
    }

    private static func isCompatibleAdditionalOption(_ option: String) -> Bool {
        guard let key = optionKey(option) else { return false }
        return ![
            "batchmode", "clearallforwardings", "controlmaster", "controlpath",
            "controlpersist", "exitonforwardfailure", "forkafterauthentication",
            "forwardagent", "localcommand", "permitlocalcommand", "proxycommand", "remotecommand",
            "requesttty", "sendenv", "sessiontype", "setenv", "stdioforward",
        ].contains(key)
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
}
