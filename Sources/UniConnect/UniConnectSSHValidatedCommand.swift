import Foundation

/// A validated SSH connection independent from the shell spelling that was imported.
struct UniConnectSSHValidatedCommand: Sendable {
    /// A password-free process invocation. Secrets are carried only in `environment`.
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let sshArguments: [String]
    private let password: String?
    private let passwordPrompt: String?
    private let verbosePasswordWrapper: Bool
    private let sshpassExecutable: String?

    init(
        sshArguments: [String],
        password: String?,
        passwordPrompt: String?,
        verbosePasswordWrapper: Bool,
        sshpassExecutable: String?
    ) {
        self.sshArguments = sshArguments
        self.password = password
        self.passwordPrompt = passwordPrompt
        self.verbosePasswordWrapper = verbosePasswordWrapper
        self.sshpassExecutable = sshpassExecutable
    }

    var usesPasswordWrapper: Bool { password != nil }

    /// Constructs a shell-free invocation, inserting app-owned options immediately
    /// before the destination so they cannot be mistaken for a remote command.
    func invocation(
        injecting options: [String],
        remoteCommand: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Invocation? {
        guard !sshArguments.isEmpty,
              Self.areSafeInjectedOptions(options),
              remoteCommand.map({ !$0.contains("\0") }) ?? true else {
            return nil
        }

        var original = Self.canonicalSSHArguments(sshArguments)
        let destination = original.removeLast()
        let arguments: [String]
        if original.last == "--" {
            original.removeLast()
            arguments = original + options + ["--", destination]
        } else {
            arguments = original + options + [destination]
        }
        let sshArguments = remoteCommand.map { arguments + [$0] } ?? arguments

        var environment = Self.minimumEnvironment(from: ambientEnvironment)
        guard let password else {
            return Invocation(
                executable: "/usr/bin/ssh",
                arguments: sshArguments,
                environment: environment
            )
        }
        guard let sshpassExecutable else { return nil }
        environment["SSHPASS"] = password
        var wrapperArguments = ["-e"]
        if verbosePasswordWrapper { wrapperArguments.append("-v") }
        if let passwordPrompt {
            wrapperArguments += ["-P", passwordPrompt]
        }
        wrapperArguments += ["/usr/bin/ssh"] + sshArguments
        return Invocation(
            executable: sshpassExecutable,
            arguments: wrapperArguments,
            environment: environment
        )
    }

    /// Produces a safely quoted command for the private, mode-0700 terminal launcher.
    ///
    /// The password may appear in that short-lived self-deleting file, but never in
    /// process arguments. Direct subprocess callers should prefer ``invocation``.
    func sensitiveCanonicalShellCommand(
        injecting options: [String],
        remoteCommand: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let invocation = invocation(
            injecting: options,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment
        ) else {
            return nil
        }
        let process = ([invocation.executable] + invocation.arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        if let password = invocation.environment["SSHPASS"] {
            return "SSHPASS=\(Self.shellQuote(password)) " + process
        }
        return process
    }

    /// Derives the non-secret connection metadata used by upload and updater paths.
    func detectedSession() -> DetectedSSHSession? {
        var arguments = ["/usr/bin/ssh"] + Self.canonicalSSHArguments(sshArguments)
        guard var session = TerminalSSHSessionDetector.parseCommandLine(arguments, for: .ssh) else {
            return nil
        }
        if let password { session.password = password }
        arguments.removeAll(keepingCapacity: false)
        return session
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        !value.contains("\0") && !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    }

    private static func areSafeInjectedOptions(_ options: [String]) -> Bool {
        var index = 0
        while index < options.count {
            switch options[index] {
            case "-t", "-T", "-4", "-6", "-C":
                index += 1
            case "-o":
                guard index + 1 < options.count,
                      isSafeArgument(options[index + 1]),
                      isSafeConfigurationOption(options[index + 1]) else {
                    return false
                }
                index += 2
            case "-R":
                guard index + 1 < options.count,
                      isSafeArgument(options[index + 1]),
                      isSafeForward(options[index + 1]) else {
                    return false
                }
                index += 2
            default:
                return false
            }
        }
        return true
    }

    private static func isSafeConfigurationOption(_ option: String) -> Bool {
        let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return false
        }
        let key = parts[0].lowercased()
        let value = parts[1].lowercased()
        if ["forwardagent", "forwardx11", "forwardx11trusted", "permitlocalcommand"].contains(key) {
            return value == "no"
        }
        return ![
            "include", "knownhostscommand", "localcommand", "permitlocalcommand",
            "pkcs11provider", "proxycommand", "remotecommand", "securitykeyprovider",
            "sessiontype",
        ].contains(key)
    }

    private static func isSafeForward(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-[]"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func expandingHome(in value: String, home: String) -> String {
        var expanded = value
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + String(expanded.dropFirst())
        } else if expanded.hasPrefix("-i~/") {
            expanded = "-i" + home + String(expanded.dropFirst(2))
        }
        return expanded
    }

    private static func canonicalSSHArguments(_ values: [String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result = values.map { expandingHome(in: $0, home: home) }
        for index in result.indices {
            if index > result.startIndex, result[result.index(before: index)] == "-i" {
                let path = result[index]
                if !path.hasPrefix("/") {
                    result[index] = URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(path)
                        .standardizedFileURL.path
                }
            } else if result[index].hasPrefix("-i"), result[index].count > 2 {
                let path = String(result[index].dropFirst(2))
                if !path.hasPrefix("/") {
                    result[index] = "-i" + URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(path)
                        .standardizedFileURL.path
                }
            }
        }
        return result
    }

    private static func minimumEnvironment(from ambient: [String: String]) -> [String: String] {
        let inheritedKeys = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SSH_AUTH_SOCK",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        ]
        var result: [String: String] = [:]
        for key in inheritedKeys {
            if let value = ambient[key], isSafeArgument(value) { result[key] = value }
        }
        for (key, value) in ambient where key.hasPrefix("LC_") && isSafeArgument(value) {
            result[key] = value
        }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // OpenSSH implements ProxyJump by spawning another `ssh`. Pin PATH so that
        // nested client cannot resolve to an imported/user-controlled executable.
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["TERM"] = ambient["TERM"].flatMap { isSafeArgument($0) ? $0 : nil } ?? "xterm-256color"
        return result
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
