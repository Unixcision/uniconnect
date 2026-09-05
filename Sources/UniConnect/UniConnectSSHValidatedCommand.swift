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
        invocation(
            prefixing: [],
            injecting: options,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment
        )
    }

    private func invocation(
        prefixing leadingOptions: [String],
        injecting options: [String],
        remoteCommand: String?,
        ambientEnvironment: [String: String]
    ) -> Invocation? {
        guard !sshArguments.isEmpty,
              Self.areSafeInjectedOptions(leadingOptions),
              Self.areSafeInjectedOptions(options),
              remoteCommand.map({ !$0.contains("\0") }) ?? true else {
            return nil
        }

        var original = Self.canonicalSSHArguments(sshArguments)
        let destination = original.removeLast()
        let arguments: [String]
        if original.last == "--" {
            original.removeLast()
            arguments = leadingOptions + original + options + ["--", destination]
        } else {
            arguments = leadingOptions + original + options + [destination]
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

    /// Constructs an invocation whose alias is pinned to a previously resolved endpoint.
    func invocation(
        injecting options: [String] = [],
        pinnedTo target: UniConnectSSHEffectiveTarget,
        remoteCommand: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Invocation? {
        invocation(
            prefixing: target.sshPinningOptions,
            injecting: options,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment
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
        return Self.sensitiveShellCommand(for: invocation)
    }

    private static func sensitiveShellCommand(for invocation: Invocation) -> String {
        let process = ([invocation.executable] + invocation.arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        if let password = invocation.environment["SSHPASS"] {
            return "SSHPASS=\(Self.shellQuote(password)) " + process
        }
        return process
    }

    /// Produces a shell command whose alias is pinned to a previously resolved endpoint.
    func sensitiveCanonicalShellCommand(
        injecting options: [String] = [],
        pinnedTo target: UniConnectSSHEffectiveTarget,
        remoteCommand: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let invocation = invocation(
            prefixing: target.sshPinningOptions,
            injecting: options,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment
        ) else {
            return nil
        }
        return Self.sensitiveShellCommand(for: invocation)
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

    /// Captures explicit endpoint values while retaining the original SSH host alias.
    func targetResolutionRequest() -> UniConnectSSHTargetResolutionRequest? {
        guard let fields = Self.targetResolutionFields(in: sshArguments) else { return nil }
        return UniConnectSSHTargetResolutionRequest(
            originalHost: fields.originalHost,
            explicitUser: fields.user,
            explicitHostName: fields.hostName,
            explicitPort: fields.port,
            explicitCanonicalizeHostname: fields.canonicalizeHostname
        )
    }

    private struct TargetResolutionFields {
        let originalHost: String
        let user: String?
        let hostName: String?
        let port: Int?
        let canonicalizeHostname: Bool?
    }

    /// Mirrors OpenSSH's command-line first-value-wins endpoint semantics. The general
    /// detector intentionally serves presentation/upload callers and historically keeps
    /// the last repeated option, so it cannot safely define immutable target ownership.
    private static func targetResolutionFields(
        in arguments: [String]
    ) -> TargetResolutionFields? {
        let valueOptions = Set<Character>("BbcDEeFIiJLlmOopQRSWw")
        var index = 0
        var user: String?
        var hostName: String?
        var port: Int?
        var canonicalizeHostname: Bool?
        var destination: String?

        func consume(_ value: String, for option: Character) -> Bool {
            guard !value.isEmpty else { return false }
            switch option {
            case "l":
                guard isASCII(value) else { return false }
                if user == nil { user = value }
            case "p":
                guard isASCII(value),
                      let parsed = Int(value),
                      (1...65_535).contains(parsed) else {
                    return false
                }
                if port == nil { port = parsed }
            case "o":
                guard let parsed = configurationOption(value) else { return false }
                switch parsed.key {
                case "user":
                    guard isASCII(parsed.value) else { return false }
                    if user == nil { user = parsed.value }
                case "hostname":
                    guard isASCII(parsed.value) else { return false }
                    if hostName == nil { hostName = parsed.value }
                case "port":
                    guard isASCII(parsed.value),
                          let parsedPort = Int(parsed.value),
                          (1...65_535).contains(parsedPort) else {
                        return false
                    }
                    if port == nil { port = parsedPort }
                case "canonicalizehostname":
                    guard isASCII(parsed.value) else { return false }
                    let parsedCanonicalization: Bool
                    switch parsed.value.lowercased() {
                    case "no", "false": parsedCanonicalization = false
                    case "yes", "true", "always": parsedCanonicalization = true
                    default: return false
                    }
                    if canonicalizeHostname == nil {
                        canonicalizeHostname = parsedCanonicalization
                    }
                default:
                    break
                }
            default:
                break
            }
            return true
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let destinationIndex = index + 1
                guard destinationIndex < arguments.count,
                      destinationIndex + 1 == arguments.count else {
                    return nil
                }
                destination = arguments[destinationIndex]
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                guard index + 1 == arguments.count else { return nil }
                destination = argument
                break
            }

            let optionCharacters = Array(argument.dropFirst())
            guard let firstOption = optionCharacters.first else { return nil }
            if valueOptions.contains(firstOption) {
                let value: String
                if optionCharacters.count > 1 {
                    value = String(optionCharacters.dropFirst())
                    index += 1
                } else {
                    let valueIndex = index + 1
                    guard valueIndex < arguments.count else { return nil }
                    value = arguments[valueIndex]
                    index += 2
                }
                guard consume(value, for: firstOption) else { return nil }
                continue
            }
            index += 1
        }

        guard canonicalizeHostname != true,
              let rawDestination = destination,
              !rawDestination.isEmpty,
              isASCII(rawDestination) else {
            return nil
        }
        let destinationComponents = rawDestination.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard destinationComponents.count <= 2,
              destinationComponents.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        let originalHost = String(destinationComponents.last ?? "")
        if destinationComponents.count == 2 {
            let destinationUser = String(destinationComponents[0])
            if user == nil { user = destinationUser }
        }
        guard !originalHost.isEmpty else { return nil }
        return TargetResolutionFields(
            originalHost: originalHost,
            user: user,
            hostName: hostName,
            port: port,
            canonicalizeHostname: canonicalizeHostname
        )
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
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./:-[]"
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

    private static func configurationOption(_ option: String) -> (key: String, value: String)? {
        guard let separator = option.firstIndex(where: {
            $0 == "=" || $0 == " " || $0 == "\t"
        }) else {
            return nil
        }
        let key = String(option[..<separator])
        guard !key.isEmpty,
              key.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39)
                      || (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A)
              }) else {
            return nil
        }
        var value = option[option.index(after: separator)...]
        while value.first == " " || value.first == "\t" { value.removeFirst() }
        while value.last == " " || value.last == "\t" { value.removeLast() }
        guard !value.isEmpty else { return nil }
        return (key.lowercased(), String(value))
    }

    private static func isASCII(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 < 0x80 }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
