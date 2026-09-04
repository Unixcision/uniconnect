import Foundation

/// Validates that a stored connection command is one safe SSH client invocation.
struct UniConnectSSHConnectCommandValidator: Sendable {
    /// The reason a connection command cannot be executed by UniConnect.
    enum Failure: Error, Equatable, Sendable {
        case empty
        case lineBreak
        case malformedQuoting
        case unsafeShellSyntax
        case unsupportedExecutable
        case invalidSSHPasswordWrapper
        case missingDestination
        case unsupportedSSHOption
        case unsafeSSHOption
        case invalidDestination
        case remoteCommand
    }

    private enum LexicalResult {
        case words([String])
        case failure(Failure)
    }

    private enum Quote: Equatable {
        case single
        case double
    }

    private enum ValidationResult {
        case command(UniConnectSSHValidatedCommand)
        case failure(Failure)
    }

    private struct PasswordWrapper {
        let sshIndex: Int
        let password: String
        let prompt: String?
        let verbose: Bool
    }

    static var trustedSSHpassPaths: [String] {
        [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]
    }

    static func trustedSSHpassExecutable(
        where isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        trustedSSHpassPaths.first(where: isExecutableFile)
    }

    private let isExecutableFile: @Sendable (String) -> Bool

    init(
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.isExecutableFile = isExecutableFile
    }

    private let sshNoValueOptions = Set<Character>("46AaCfGgKkMNnqsTtVvXxYy")
    private let sshValueOptions = Set<Character>("BbcDEeFIiJLlmOopQRSWw")
    // These modes suppress, background, or reinterpret the app-owned remote tmux command.
    private let incompatibleNoValueOptions = Set<Character>("AfGKMNnsTVXY")
    // These options load executable/config payloads, write locally, forward ports, or skip a shell.
    private let unsafeOrIncompatibleValueOptions = Set<Character>("DEFILOQRSWw")
    // OpenSSH evaluates these values as commands, executable providers, or additional config.
    private let unsafeConfigurationKeys: Set<String> = [
        "addkeystoagent",
        "batchmode",
        "clearallforwardings",
        "controlmaster",
        "controlpath",
        "controlpersist",
        "dynamicforward",
        "exitonforwardfailure",
        "forwardagent",
        "forwardx11",
        "forwardx11trusted",
        "gssapidelegatecredentials",
        "include",
        "knownhostscommand",
        "localcommand",
        "localforward",
        "permitlocalcommand",
        "pkcs11provider",
        "proxycommand",
        "remotecommand",
        "remoteforward",
        "requesttty",
        "securitykeyprovider",
        "sendenv",
        "sessiontype",
        "setenv",
        "stdioforward",
    ]

    /// Returns the first validation failure, or `nil` for a supported connection command.
    func validate(_ command: String) -> Failure? {
        switch validationResult(for: command) {
        case .command:
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Parses and validates one command into its shell-independent representation.
    func validatedCommand(_ command: String) -> UniConnectSSHValidatedCommand? {
        guard case .command(let validated) = validationResult(for: command) else {
            return nil
        }
        return validated
    }

    private func validationResult(for command: String) -> ValidationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !command.unicodeScalars.contains(where: CharacterSet.newlines.contains) else {
            return .failure(.lineBreak)
        }

        let words: [String]
        switch lex(trimmed) {
        case .words(let parsedWords):
            words = parsedWords
        case .failure(let failure):
            return .failure(failure)
        }

        guard let first = words.first else { return .failure(.empty) }
        if isTrustedSSHExecutable(first) {
            if let failure = validateSSHInvocation(words, executableIndex: 0) {
                return .failure(failure)
            }
            return .command(UniConnectSSHValidatedCommand(
                sshArguments: Array(words.dropFirst()),
                password: nil,
                passwordPrompt: nil,
                verbosePasswordWrapper: false,
                sshpassExecutable: nil
            ))
        }
        if isTrustedSSHpassSpelling(first) {
            let executable: String?
            if first == "sshpass" {
                executable = Self.trustedSSHpassExecutable(where: isExecutableFile)
            } else {
                guard isExecutableFile(first) else { return .failure(.unsupportedExecutable) }
                executable = first
            }
            switch parseSSHPasswordWrapper(words) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let wrapper):
                if let failure = validateSSHInvocation(words, executableIndex: wrapper.sshIndex) {
                    return .failure(failure)
                }
                return .command(UniConnectSSHValidatedCommand(
                    sshArguments: Array(words.dropFirst(wrapper.sshIndex + 1)),
                    password: wrapper.password,
                    passwordPrompt: wrapper.prompt,
                    verbosePasswordWrapper: wrapper.verbose,
                    sshpassExecutable: executable
                ))
            }
        }
        return .failure(.unsupportedExecutable)
    }

    private func parseSSHPasswordWrapper(_ words: [String]) -> Result<PasswordWrapper, Failure> {
        var index = 1
        var password: String?
        var prompt: String?
        var verbose = false
        while index < words.count {
            let argument = words[index]
            if argument == "--" {
                index += 1
                break
            }
            if argument == "-v" {
                verbose = true
                index += 1
                continue
            }
            guard argument.hasPrefix("-"), argument != "-" else { break }
            guard argument.count >= 2 else { return .failure(.invalidSSHPasswordWrapper) }

            let optionIndex = argument.index(after: argument.startIndex)
            let option = argument[optionIndex]
            guard option == "p" || option == "P" else {
                return .failure(.invalidSSHPasswordWrapper)
            }

            let attachedValue = argument.index(after: optionIndex)
            let value: String
            if attachedValue < argument.endIndex {
                value = String(argument[attachedValue...])
                index += 1
            } else {
                index += 1
                guard index < words.count else { return .failure(.invalidSSHPasswordWrapper) }
                value = words[index]
                index += 1
            }
            guard !value.isEmpty else { return .failure(.invalidSSHPasswordWrapper) }
            if option == "p" { password = value } else { prompt = value }
        }

        guard let password,
              index < words.count,
              isTrustedSSHExecutable(words[index]) else {
            return .failure(.invalidSSHPasswordWrapper)
        }
        return .success(PasswordWrapper(
            sshIndex: index,
            password: password,
            prompt: prompt,
            verbose: verbose
        ))
    }

    private func validateSSHInvocation(_ words: [String], executableIndex: Int) -> Failure? {
        var index = executableIndex + 1
        while index < words.count {
            let argument = words[index]
            if argument == "--" {
                index += 1
                guard index < words.count else { return .missingDestination }
                let destination = words[index]
                guard isSafeDestination(destination) else { return .invalidDestination }
                return index + 1 == words.count ? nil : .remoteCommand
            }
            if !argument.hasPrefix("-") || argument == "-" {
                guard isSafeDestination(argument) else { return .invalidDestination }
                return index + 1 == words.count ? nil : .remoteCommand
            }

            let optionCharacters = Array(argument.dropFirst())
            guard let firstOption = optionCharacters.first else { return .unsupportedSSHOption }
            if sshValueOptions.contains(firstOption) {
                let value: String
                if optionCharacters.count > 1 {
                    value = String(optionCharacters.dropFirst())
                    index += 1
                } else {
                    index += 1
                    guard index < words.count else { return .unsupportedSSHOption }
                    value = words[index]
                    index += 1
                }
                if let failure = validateSSHOption(firstOption, value: value) {
                    return failure
                }
                continue
            }

            guard optionCharacters.allSatisfy(sshNoValueOptions.contains) else {
                return .unsupportedSSHOption
            }
            guard optionCharacters.allSatisfy({ !incompatibleNoValueOptions.contains($0) }) else {
                return .unsafeSSHOption
            }
            index += 1
        }
        return .missingDestination
    }

    private func validateSSHOption(_ option: Character, value: String) -> Failure? {
        guard !value.isEmpty else { return .unsupportedSSHOption }
        guard !unsafeOrIncompatibleValueOptions.contains(option) else { return .unsafeSSHOption }

        switch option {
        case "p":
            guard let port = Int(value), (1...65_535).contains(port) else {
                return .unsupportedSSHOption
            }
        case "J":
            guard isSafeJumpList(value) else { return .invalidDestination }
        case "o":
            return validateConfigurationOption(value)
        default:
            break
        }
        return nil
    }

    private func validateConfigurationOption(_ value: String) -> Failure? {
        guard let separator = value.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            return .unsupportedSSHOption
        }
        let key = String(value[..<separator]).lowercased()
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return .unsupportedSSHOption
        }
        guard !unsafeConfigurationKeys.contains(key) else { return .unsafeSSHOption }

        let optionValue = value[value.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard !optionValue.isEmpty else { return .unsupportedSSHOption }
        if key == "proxyjump" {
            guard isSafeJumpList(optionValue) else { return .invalidDestination }
        }
        return nil
    }

    private func isTrustedSSHExecutable(_ word: String) -> Bool {
        word == "ssh" || word == "/usr/bin/ssh"
    }

    private func isTrustedSSHpassSpelling(_ word: String) -> Bool {
        word == "sshpass" || Self.trustedSSHpassPaths.contains(word)
    }

    private func isSafeDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return false }
        let components = destination.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count <= 2, components.allSatisfy({ !$0.isEmpty }) else { return false }

        let usernameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-%")
        if components.count == 2,
           !components[0].unicodeScalars.allSatisfy(usernameCharacters.contains) {
            return false
        }

        let host = String(components.last ?? "")
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+:%-[]")
        guard host.unicodeScalars.allSatisfy(hostCharacters.contains) else { return false }
        if host.contains("[") || host.contains("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
            let inner = host.dropFirst().dropLast()
            guard !inner.isEmpty, inner.contains(":"), !inner.contains("["), !inner.contains("]") else {
                return false
            }
        }
        return true
    }

    private func isSafeJumpList(_ value: some StringProtocol) -> Bool {
        let jumpCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@:%-[],")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(jumpCharacters.contains)
    }

    private func lex(_ command: String) -> LexicalResult {
        if command.unicodeScalars.contains(where: { scalar in
            (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7f
        }) {
            return .failure(.unsafeShellSyntax)
        }

        var words: [String] = []
        var current = ""
        var tokenStarted = false
        var quote: Quote?
        var escaping = false
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)

            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                index = nextIndex
                continue
            }

            if quote == .single {
                if character == "'" {
                    quote = nil
                } else {
                    current.append(character)
                }
                index = nextIndex
                continue
            }

            if character == "\\" {
                escaping = true
                tokenStarted = true
                index = nextIndex
                continue
            }
            if character == "\"" {
                if quote == .double {
                    quote = nil
                } else {
                    quote = .double
                    tokenStarted = true
                }
                index = nextIndex
                continue
            }
            if quote == nil, character == "'" {
                quote = .single
                tokenStarted = true
                index = nextIndex
                continue
            }

            if character == "`" { return .failure(.unsafeShellSyntax) }
            if character == "$" {
                guard let expansion = allowedHomeExpansion(in: command, at: index) else {
                    return .failure(.unsafeShellSyntax)
                }
                current.append(contentsOf: expansion.text)
                tokenStarted = true
                index = expansion.endIndex
                continue
            }

            if quote == nil {
                if character == " " || character == "\t" {
                    if tokenStarted {
                        words.append(current)
                        current = ""
                        tokenStarted = false
                    }
                    index = nextIndex
                    continue
                }
                if "|;&<>(){}*?".contains(character) {
                    return .failure(.unsafeShellSyntax)
                }
                if character == "#", !tokenStarted {
                    return .failure(.unsafeShellSyntax)
                }
            }

            current.append(character)
            tokenStarted = true
            index = nextIndex
        }

        guard quote == nil, !escaping else { return .failure(.malformedQuoting) }
        if tokenStarted { words.append(current) }
        return .words(words)
    }

    private func allowedHomeExpansion(
        in command: String,
        at index: String.Index
    ) -> (text: String, endIndex: String.Index)? {
        let suffix = command[index...]
        if suffix.hasPrefix("${HOME}") {
            return ("${HOME}", command.index(index, offsetBy: 7))
        }
        guard suffix.hasPrefix("$HOME") else { return nil }
        let endIndex = command.index(index, offsetBy: 5)
        if endIndex < command.endIndex {
            let following = command[endIndex]
            guard !(following.isLetter || following.isNumber || following == "_") else { return nil }
        }
        return ("$HOME", endIndex)
    }
}
