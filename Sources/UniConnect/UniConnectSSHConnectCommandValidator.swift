import Foundation

/// Validates that a stored connection command is one safe SSH client invocation.
struct UniConnectSSHConnectCommandValidator: Sendable {
    /// The reason a connection command cannot be executed by UniConnect.
    enum Failure: Equatable, Sendable {
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

    private let sshNoValueOptions = Set<Character>("46AaCfGgKkMNnqsTtVvXxYy")
    private let sshValueOptions = Set<Character>("BbcDEeFIiJLlmOopQRSWw")
    // These modes suppress, background, or reinterpret the app-owned remote tmux command.
    private let incompatibleNoValueOptions = Set<Character>("fGNnsTV")
    // These options load executable/config payloads, write locally, forward ports, or skip a shell.
    private let unsafeOrIncompatibleValueOptions = Set<Character>("DEFILOQRWw")
    // OpenSSH evaluates these values as commands, executable providers, or additional config.
    private let unsafeConfigurationKeys: Set<String> = [
        "include",
        "knownhostscommand",
        "localcommand",
        "permitlocalcommand",
        "pkcs11provider",
        "proxycommand",
        "remotecommand",
        "securitykeyprovider",
        "sessiontype",
    ]

    /// Returns the first validation failure, or `nil` for a supported connection command.
    func validate(_ command: String) -> Failure? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !command.unicodeScalars.contains(where: CharacterSet.newlines.contains) else {
            return .lineBreak
        }

        let words: [String]
        switch lex(trimmed) {
        case .words(let parsedWords):
            words = parsedWords
        case .failure(let failure):
            return failure
        }

        guard let first = words.first else { return .empty }
        if isExecutable(first, named: "ssh") {
            return validateSSHInvocation(words, executableIndex: 0)
        }
        if isExecutable(first, named: "sshpass") {
            return validateSSHPasswordWrapper(words)
        }
        return .unsupportedExecutable
    }

    private func validateSSHPasswordWrapper(_ words: [String]) -> Failure? {
        var index = 1
        while index < words.count {
            let argument = words[index]
            if argument == "--" {
                index += 1
                break
            }
            if argument == "-e" || argument == "-v" {
                index += 1
                continue
            }
            guard argument.hasPrefix("-"), argument != "-" else { break }
            guard argument.count >= 2 else { return .invalidSSHPasswordWrapper }

            let optionIndex = argument.index(after: argument.startIndex)
            let option = argument[optionIndex]
            guard option == "p" || option == "f" || option == "d" || option == "P" else {
                return .invalidSSHPasswordWrapper
            }

            let attachedValue = argument.index(after: optionIndex)
            if attachedValue < argument.endIndex {
                index += 1
            } else {
                index += 1
                guard index < words.count else { return .invalidSSHPasswordWrapper }
                index += 1
            }
        }

        guard index < words.count, isExecutable(words[index], named: "ssh") else {
            return .invalidSSHPasswordWrapper
        }
        return validateSSHInvocation(words, executableIndex: index)
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

    private func isExecutable(_ word: String, named expectedName: String) -> Bool {
        if word == expectedName { return true }
        guard word.hasPrefix("/") else { return false }
        return (word as NSString).lastPathComponent == expectedName
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
