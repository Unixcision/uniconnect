import Darwin
import Foundation

/// Resolves SSH aliases from bounded, inert `ssh_config` parsing without launching OpenSSH.
actor UniConnectSSHConfigTargetResolver: UniConnectSSHTargetResolving {
    /// Resource ceilings applied independently to each batch resolution.
    struct Limits: Equatable, Sendable {
        let maximumRequests: Int
        let maximumFiles: Int
        let maximumIncludeDepth: Int
        let maximumTotalBytes: Int
        let maximumFileBytes: Int
        let maximumLineBytes: Int
        let maximumDirectives: Int
        let maximumIncludeMatches: Int
        let maximumDirectoryEntries: Int
        let maximumTokensPerLine: Int
        let maximumIncludeWork: Int
        let maximumPatternWork: Int

        init(
            maximumRequests: Int = 256,
            maximumFiles: Int = 64,
            maximumIncludeDepth: Int = 12,
            maximumTotalBytes: Int = 1_048_576,
            maximumFileBytes: Int = 262_144,
            maximumLineBytes: Int = 16_384,
            maximumDirectives: Int = 16_384,
            maximumIncludeMatches: Int = 256,
            maximumDirectoryEntries: Int = 4_096,
            maximumTokensPerLine: Int = 256,
            maximumIncludeWork: Int = 16_384,
            maximumPatternWork: Int = 4_194_304
        ) {
            self.maximumRequests = maximumRequests
            self.maximumFiles = maximumFiles
            self.maximumIncludeDepth = maximumIncludeDepth
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumFileBytes = maximumFileBytes
            self.maximumLineBytes = maximumLineBytes
            self.maximumDirectives = maximumDirectives
            self.maximumIncludeMatches = maximumIncludeMatches
            self.maximumDirectoryEntries = maximumDirectoryEntries
            self.maximumTokensPerLine = maximumTokensPerLine
            self.maximumIncludeWork = maximumIncludeWork
            self.maximumPatternWork = maximumPatternWork
        }

        fileprivate var isUsable: Bool {
            maximumRequests > 0
                && maximumFiles > 0
                && maximumIncludeDepth >= 0
                && maximumTotalBytes > 0
                && maximumFileBytes > 0
                && maximumFileBytes <= maximumTotalBytes
                && maximumLineBytes > 0
                && maximumDirectives > 0
                && maximumIncludeMatches > 0
                && maximumDirectoryEntries > 0
                && maximumTokensPerLine > 0
                && maximumIncludeWork > 0
                && maximumPatternWork > 0
        }
    }

    private struct ConfigurationRoot: Sendable {
        let fileURL: URL
        let includeBaseDirectoryURL: URL
        let allowsHomeIncludeExpansion: Bool
    }

    private struct Directive: Sendable {
        let keyword: String
        let arguments: [String]
        let argumentsContainedBackslash: Bool
    }

    private enum LoadedFile {
        case missing
        case directives([Directive])
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private enum Applicability {
        case yes
        case no
        case unknown
    }

    private struct Accumulator {
        var user: String?
        var hostName: String?
        var port: Int?
        var canonicalizeHostname: Bool?
    }

    private enum ResolutionFailure: Error {
        case indeterminate
    }

    private struct FileLoader {
        let fileManager: FileManager
        let homeDirectoryURL: URL
        let limits: Limits
        let afterFileStat: (@Sendable (URL) throws -> Void)?

        var cache: [FileIdentity: LoadedFile] = [:]
        var includeExpansionCache: [String: [URL]] = [:]
        var totalBytes = 0
        var fileVisits = 0
        var directiveVisits = 0
        var includeMatches = 0
        var directoryEntries = 0
        var includeWork = 0
        var patternWork = 0

        mutating func beginRequest() {
            directiveVisits = 0
            includeMatches = 0
            includeWork = 0
            patternWork = 0
        }

        mutating func load(_ url: URL) throws -> (identity: FileIdentity?, file: LoadedFile) {
            guard url.isFileURL else { throw ResolutionFailure.indeterminate }
            let normalizedURL = url.standardizedFileURL
            let path = normalizedURL.path
            guard !path.isEmpty,
                  !path.contains("\0"),
                  path.utf8.count <= 4_096 else {
                throw ResolutionFailure.indeterminate
            }

            // OpenSSH permits symlinked config files. Resolve them during this open,
            // then bind metadata validation and reads to the same nonblocking descriptor.
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            let openError = errno
            guard descriptor >= 0 else {
                if openError == ENOENT {
                    return (nil, .missing)
                }
                throw ResolutionFailure.indeterminate
            }
            defer { _ = Darwin.close(descriptor) }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == 0 || metadata.st_uid == getuid(),
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_size >= 0 else {
                throw ResolutionFailure.indeterminate
            }
            let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
            if let cached = cache[identity] {
                return (identity, cached)
            }

            fileVisits += 1
            guard fileVisits <= limits.maximumFiles else {
                throw ResolutionFailure.indeterminate
            }
            try afterFileStat?(normalizedURL)

            let data = try readBounded(from: descriptor)
            try validateLineLengthsAndControls(in: data)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ResolutionFailure.indeterminate
            }

            var directives: [Directive] = []
            directives.reserveCapacity(min(256, text.count / 24))
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(rawLine)
                if line.last == "\r" { line.removeLast() }
                if let directive = try Self.lexDirective(
                    line,
                    maximumTokens: limits.maximumTokensPerLine
                ) {
                    directives.append(directive)
                    guard directives.count <= limits.maximumDirectives else {
                        throw ResolutionFailure.indeterminate
                    }
                }
            }

            let loaded = LoadedFile.directives(directives)
            cache[identity] = loaded
            return (identity, loaded)
        }

        private mutating func readBounded(from descriptor: Int32) throws -> Data {
            guard totalBytes <= limits.maximumTotalBytes else {
                throw ResolutionFailure.indeterminate
            }
            let remainingTotalBytes = limits.maximumTotalBytes - totalBytes
            let byteLimit = min(limits.maximumFileBytes, remainingTotalBytes)
            guard byteLimit < Int.max else { throw ResolutionFailure.indeterminate }
            // Do not trust st_size: one extra byte detects a file that was already
            // oversized or grew after fstat without ever reading it unboundedly.
            let maximumReadBytes = byteLimit + 1

            var data = Data()
            data.reserveCapacity(min(maximumReadBytes, 16_384))
            var buffer = [UInt8](
                repeating: 0,
                count: min(maximumReadBytes, 16_384)
            )
            while data.count < maximumReadBytes {
                let requestedBytes = min(buffer.count, maximumReadBytes - data.count)
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(descriptor, rawBuffer.baseAddress, requestedBytes)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ResolutionFailure.indeterminate }
                guard count > 0 else { break }

                guard totalBytes <= Int.max - count else {
                    totalBytes = Int.max
                    throw ResolutionFailure.indeterminate
                }
                totalBytes += count
                guard totalBytes <= limits.maximumTotalBytes else {
                    throw ResolutionFailure.indeterminate
                }
                data.append(buffer, count: count)
            }
            guard data.count <= byteLimit else {
                throw ResolutionFailure.indeterminate
            }
            return data
        }

        mutating func countDirectiveVisit() throws {
            directiveVisits += 1
            guard directiveVisits <= limits.maximumDirectives else {
                throw ResolutionFailure.indeterminate
            }
        }

        mutating func chargeIncludeWork(_ amount: Int = 1) throws {
            guard amount >= 0,
                  includeWork <= limits.maximumIncludeWork - amount else {
                throw ResolutionFailure.indeterminate
            }
            includeWork += amount
        }

        mutating func chargePatternWork(pattern: String, candidate: String) throws {
            let patternBytes = pattern.utf8.count
            let candidateBytes = candidate.utf8.count
            guard patternBytes == 0
                    || candidateBytes <= Int.max / patternBytes else {
                throw ResolutionFailure.indeterminate
            }
            let amount = max(1, patternBytes * candidateBytes)
            guard patternWork <= limits.maximumPatternWork - amount else {
                throw ResolutionFailure.indeterminate
            }
            patternWork += amount
        }

        mutating func expandInclude(
            _ rawPattern: String,
            relativeTo baseDirectoryURL: URL,
            allowsHomeExpansion: Bool
        ) throws -> [URL] {
            try chargeIncludeWork()
            guard !rawPattern.isEmpty,
                  rawPattern.utf8.count <= 4_096,
                  !rawPattern.contains("\0"),
                  !rawPattern.contains("%"),
                  !rawPattern.contains("$"),
                  !rawPattern.contains("`"),
                  !rawPattern.contains("\\"),
                  !rawPattern.contains("{"),
                  !rawPattern.contains("}"),
                  !rawPattern.contains("[") && !rawPattern.contains("]") else {
                throw ResolutionFailure.indeterminate
            }
            guard allowsHomeExpansion || !rawPattern.hasPrefix("~") else {
                throw ResolutionFailure.indeterminate
            }
            let containsWildcard = rawPattern.contains("*") || rawPattern.contains("?")
            let cacheKey = (allowsHomeExpansion ? "home\0" : "system\0")
                + baseDirectoryURL.standardizedFileURL.path + "\0" + rawPattern
            if let cached = includeExpansionCache[cacheKey] {
                try chargeIncludeWork(cached.count)
                includeMatches += cached.count
                guard includeMatches <= limits.maximumIncludeMatches else {
                    throw ResolutionFailure.indeterminate
                }
                return cached
            }

            let expanded: String
            if rawPattern == "~" {
                expanded = homeDirectoryURL.path
            } else if rawPattern.hasPrefix("~/") {
                expanded = homeDirectoryURL
                    .appendingPathComponent(String(rawPattern.dropFirst(2)))
                    .path
            } else if rawPattern.hasPrefix("~") {
                // Resolving another account would require NSS/user-database behavior
                // that is intentionally outside this inert parser.
                throw ResolutionFailure.indeterminate
            } else if rawPattern.hasPrefix("/") {
                expanded = rawPattern
            } else {
                expanded = baseDirectoryURL.appendingPathComponent(rawPattern).path
            }

            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard standardized.utf8.count <= 4_096 else {
                throw ResolutionFailure.indeterminate
            }
            let components = (standardized as NSString).pathComponents
            guard components.first == "/" else { throw ResolutionFailure.indeterminate }

            var candidates = [URL(fileURLWithPath: "/", isDirectory: true)]
            for component in components.dropFirst() {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      component.utf8.count <= 255 else {
                    throw ResolutionFailure.indeterminate
                }
                if component.contains("*") || component.contains("?") {
                    var expandedCandidates: [URL] = []
                    for directory in candidates {
                        try chargeIncludeWork()
                        var isDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                            continue
                        }
                        guard isDirectory.boolValue else { continue }
                        var enumerationFailed = false
                        guard let children = fileManager.enumerator(
                            at: directory,
                            includingPropertiesForKeys: nil,
                            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                            errorHandler: { _, _ in
                                enumerationFailed = true
                                return false
                            }
                        ) else {
                            throw ResolutionFailure.indeterminate
                        }
                        for case let child as URL in children {
                            try chargeIncludeWork()
                            directoryEntries += 1
                            guard directoryEntries <= limits.maximumDirectoryEntries else {
                                throw ResolutionFailure.indeterminate
                            }
                            let name = child.lastPathComponent
                            if name.hasPrefix("."), !component.hasPrefix(".") { continue }
                            try chargePatternWork(pattern: component, candidate: name)
                            if Self.wildcardMatch(
                                pattern: component,
                                candidate: name,
                                caseInsensitive: false
                            ) {
                                guard expandedCandidates.count < limits.maximumIncludeMatches else {
                                    throw ResolutionFailure.indeterminate
                                }
                                expandedCandidates.append(child)
                            }
                        }
                        guard !enumerationFailed else { throw ResolutionFailure.indeterminate }
                    }
                    candidates = expandedCandidates.sorted(by: Self.lexicalPathLess)
                } else {
                    try chargeIncludeWork(candidates.count)
                    candidates = candidates.map { $0.appendingPathComponent(component) }
                }
                guard candidates.count <= limits.maximumIncludeMatches else {
                    throw ResolutionFailure.indeterminate
                }
            }

            var existing: [URL] = []
            existing.reserveCapacity(candidates.count)
            for candidate in candidates {
                try chargeIncludeWork()
                if fileManager.fileExists(atPath: candidate.path) {
                    existing.append(candidate)
                }
            }
            guard !containsWildcard || existing.count <= 1 else {
                // glob(3) sorts with the process locale. Claiming a deterministic
                // first-value result across machines would be unsafe when order matters.
                throw ResolutionFailure.indeterminate
            }
            includeMatches += existing.count
            guard includeMatches <= limits.maximumIncludeMatches else {
                throw ResolutionFailure.indeterminate
            }
            let sorted = existing.sorted(by: Self.lexicalPathLess)
            includeExpansionCache[cacheKey] = sorted
            return sorted
        }

        private func validateLineLengthsAndControls(in data: Data) throws {
            var lineBytes = 0
            for byte in data {
                if byte == 0x0A {
                    lineBytes = 0
                    continue
                }
                lineBytes += 1
                guard lineBytes <= limits.maximumLineBytes,
                      byte != 0,
                      byte != 0x7F,
                      byte >= 0x20 || byte == 0x09 || byte == 0x0D else {
                    throw ResolutionFailure.indeterminate
                }
            }
        }

        private static func lexDirective(
            _ line: String,
            maximumTokens: Int
        ) throws -> Directive? {
            var index = line.startIndex
            while index < line.endIndex, isConfigSeparator(line[index]) {
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] != "#" else { return nil }

            let keywordStart = index
            while index < line.endIndex,
                  !isConfigSeparator(line[index]),
                  line[index] != "=",
                  line[index] != "#" {
                index = line.index(after: index)
            }
            let keyword = String(line[keywordStart..<index]).lowercased()
            guard !keyword.isEmpty,
                  keyword.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw ResolutionFailure.indeterminate
            }

            while index < line.endIndex, isConfigSeparator(line[index]) {
                index = line.index(after: index)
            }
            if index < line.endIndex, line[index] == "=" {
                index = line.index(after: index)
                while index < line.endIndex, isConfigSeparator(line[index]) {
                    index = line.index(after: index)
                }
            }

            var arguments: [String] = []
            var current = ""
            var tokenStarted = false
            var quote: Character?
            var argumentsContainedBackslash = false

            while index < line.endIndex {
                let character = line[index]
                index = line.index(after: index)

                if character == "\\" {
                    argumentsContainedBackslash = true
                    if index < line.endIndex {
                        let next = line[index]
                        let escapesNext = next == "'"
                            || next == "\""
                            || next == "\\"
                            || (quote == nil && next == " ")
                        if escapesNext {
                            current.append(next)
                            index = line.index(after: index)
                        } else {
                            current.append(character)
                        }
                    } else {
                        current.append(character)
                    }
                    tokenStarted = true
                    continue
                }
                if let activeQuote = quote {
                    if character == activeQuote {
                        quote = nil
                    } else {
                        current.append(character)
                    }
                    tokenStarted = true
                    continue
                }
                if character == "\"" {
                    quote = character
                    tokenStarted = true
                    continue
                }
                if character == "#", !tokenStarted {
                    break
                }
                if isConfigSeparator(character) {
                    if tokenStarted {
                        arguments.append(current)
                        guard arguments.count <= maximumTokens else {
                            throw ResolutionFailure.indeterminate
                        }
                        current = ""
                        tokenStarted = false
                    }
                    continue
                }
                current.append(character)
                tokenStarted = true
            }
            guard quote == nil else { throw ResolutionFailure.indeterminate }
            if tokenStarted { arguments.append(current) }
            guard arguments.count <= maximumTokens else {
                throw ResolutionFailure.indeterminate
            }
            return Directive(
                keyword: keyword,
                arguments: arguments,
                argumentsContainedBackslash: argumentsContainedBackslash
            )
        }

        private static func isConfigSeparator(_ character: Character) -> Bool {
            character == " " || character == "\t"
        }

        fileprivate static func wildcardMatch(
            pattern: String,
            candidate: String,
            caseInsensitive: Bool
        ) -> Bool {
            let pattern = Array(pattern)
            let candidate = Array(candidate)
            var previous = Array(repeating: false, count: candidate.count + 1)
            previous[0] = true

            for patternCharacter in pattern {
                var next = Array(repeating: false, count: candidate.count + 1)
                if patternCharacter == "*" {
                    next[0] = previous[0]
                    if !candidate.isEmpty {
                        for index in 1...candidate.count {
                            next[index] = previous[index] || next[index - 1]
                        }
                    }
                } else if patternCharacter == "?" {
                    if !candidate.isEmpty {
                        for index in 1...candidate.count {
                            next[index] = previous[index - 1]
                        }
                    }
                } else if !candidate.isEmpty {
                    for index in 1...candidate.count {
                        let equal: Bool
                        if caseInsensitive {
                            equal = String(patternCharacter).caseInsensitiveCompare(
                                String(candidate[index - 1])
                            ) == .orderedSame
                        } else {
                            equal = patternCharacter == candidate[index - 1]
                        }
                        next[index] = previous[index - 1] && equal
                    }
                }
                previous = next
            }
            return previous[candidate.count]
        }

        private static func lexicalPathLess(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
    }

    private let roots: [ConfigurationRoot]
    private let homeDirectoryURL: URL
    private let defaultUser: String?
    private let limits: Limits
    private let fileManager: FileManager
    private let afterFileStat: (@Sendable (URL) throws -> Void)?

    /// Creates an inert resolver whose configuration roots are fully caller-controlled.
    init(
        userConfigurationURL: URL?,
        systemConfigurationURL: URL?,
        homeDirectoryURL: URL,
        defaultUser: String?,
        limits: Limits = Limits(),
        fileManager: FileManager = .default,
        afterFileStat: (@Sendable (URL) throws -> Void)? = nil
    ) {
        var configuredRoots: [ConfigurationRoot] = []
        if let userConfigurationURL {
            configuredRoots.append(ConfigurationRoot(
                fileURL: userConfigurationURL.standardizedFileURL,
                includeBaseDirectoryURL: userConfigurationURL
                    .deletingLastPathComponent().standardizedFileURL,
                allowsHomeIncludeExpansion: true
            ))
        }
        if let systemConfigurationURL {
            configuredRoots.append(ConfigurationRoot(
                fileURL: systemConfigurationURL.standardizedFileURL,
                includeBaseDirectoryURL: systemConfigurationURL
                    .deletingLastPathComponent().standardizedFileURL,
                allowsHomeIncludeExpansion: false
            ))
        }
        self.roots = configuredRoots
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.defaultUser = defaultUser
        self.limits = limits
        self.fileManager = fileManager
        self.afterFileStat = afterFileStat
    }

    /// Creates the production resolver using standard OpenSSH paths and the passwd database.
    init(fileManager: FileManager = .default, limits: Limits = Limits()) {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        self.roots = [
            ConfigurationRoot(
                fileURL: home.appendingPathComponent(".ssh/config"),
                includeBaseDirectoryURL: home.appendingPathComponent(".ssh", isDirectory: true),
                allowsHomeIncludeExpansion: true
            ),
            ConfigurationRoot(
                fileURL: URL(fileURLWithPath: "/etc/ssh/ssh_config"),
                includeBaseDirectoryURL: URL(fileURLWithPath: "/etc/ssh", isDirectory: true),
                allowsHomeIncludeExpansion: false
            ),
        ]
        self.homeDirectoryURL = home
        self.defaultUser = Self.passwdUserName()
        self.limits = limits
        self.fileManager = fileManager
        self.afterFileStat = nil
    }

    func resolve(
        _ requests: [UniConnectSSHTargetResolutionRequest]
    ) async -> [UniConnectSSHTargetResolutionOutcome] {
        resolveSynchronously(requests, fileManager: fileManager)
    }

    /// Runs the same bounded, inert parser before synchronous session restoration.
    ///
    /// Configuration is immutable and each invocation owns its loader/cache. This seam
    /// performs local reads only; it never starts SSH, resolves DNS, or waits on an actor.
    nonisolated func resolveForStartup(
        _ requests: [UniConnectSSHTargetResolutionRequest]
    ) -> [UniConnectSSHTargetResolutionOutcome] {
        // FileManager is not Sendable in every supported SDK. Use an invocation-local
        // instance rather than accessing the actor-owned injectable instance here.
        resolveSynchronously(requests, fileManager: FileManager())
    }

    nonisolated private func resolveSynchronously(
        _ requests: [UniConnectSSHTargetResolutionRequest],
        fileManager: FileManager
    ) -> [UniConnectSSHTargetResolutionOutcome] {
        guard limits.isUsable, requests.count <= limits.maximumRequests else {
            return Array(repeating: .indeterminate, count: requests.count)
        }
        var loader = FileLoader(
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL,
            limits: limits,
            afterFileStat: afterFileStat
        )
        var outcomes: [UniConnectSSHTargetResolutionOutcome] = []
        outcomes.reserveCapacity(requests.count)
        for request in requests {
            loader.beginRequest()
            do {
                outcomes.append(try resolve(request, loader: &loader))
            } catch {
                outcomes.append(.indeterminate)
            }
        }
        return outcomes
    }

    nonisolated private func resolve(
        _ request: UniConnectSSHTargetResolutionRequest,
        loader: inout FileLoader
    ) throws -> UniConnectSSHTargetResolutionOutcome {
        let originalHost = request.originalHost.trimmingCharacters(in: .whitespacesAndNewlines)
        // Host and Match originalhost operate on the command-line spelling. Validate
        // it now, but defer bracket/trailing-dot normalization until the final key.
        guard UniConnectSSHEffectiveTarget.normalizedHost(originalHost) != nil,
              request.explicitPort.map({ (1...65_535).contains($0) }) ?? true,
              request.explicitCanonicalizeHostname != true else {
            throw ResolutionFailure.indeterminate
        }
        let explicitUser = try normalizedOptionalUser(request.explicitUser)
        let explicitHostName = try normalizedOptionalHost(request.explicitHostName)

        var accumulator = Accumulator(
            user: explicitUser,
            hostName: explicitHostName,
            port: request.explicitPort,
            canonicalizeHostname: request.explicitCanonicalizeHostname
        )
        for root in roots {
            var applicability = Applicability.yes
            var activeFiles: Set<FileIdentity> = []
            try interpret(
                root.fileURL,
                includeBaseDirectoryURL: root.includeBaseDirectoryURL,
                originalHost: originalHost,
                depth: 0,
                allowsHomeIncludeExpansion: root.allowsHomeIncludeExpansion,
                applicability: &applicability,
                accumulator: &accumulator,
                activeFiles: &activeFiles,
                loader: &loader
            )
        }

        guard let target = UniConnectSSHEffectiveTarget(
            user: accumulator.user ?? defaultUser ?? "",
            host: accumulator.hostName ?? originalHost,
            port: accumulator.port ?? 22
        ) else {
            throw ResolutionFailure.indeterminate
        }
        return .resolved(target)
    }

    nonisolated private func interpret(
        _ fileURL: URL,
        includeBaseDirectoryURL: URL,
        originalHost: String,
        depth: Int,
        allowsHomeIncludeExpansion: Bool,
        applicability: inout Applicability,
        accumulator: inout Accumulator,
        activeFiles: inout Set<FileIdentity>,
        loader: inout FileLoader
    ) throws {
        guard depth <= limits.maximumIncludeDepth else {
            throw ResolutionFailure.indeterminate
        }
        let loaded = try loader.load(fileURL)
        guard case .directives(let directives) = loaded.file else { return }
        guard let identity = loaded.identity,
              activeFiles.insert(identity).inserted else {
            throw ResolutionFailure.indeterminate
        }

        do {
            for directive in directives {
                try loader.countDirectiveVisit()
                switch directive.keyword {
                case "host":
                    applicability = try hostApplicability(
                        patterns: directive.arguments,
                        originalHost: originalHost,
                        loader: &loader
                    ) ? .yes : .no
                case "match":
                    applicability = try matchApplicability(
                        directive.arguments,
                        originalHost: originalHost,
                        loader: &loader
                    )
                case "hostname":
                    try applyHostName(
                        directive.arguments,
                        applicability: applicability,
                        accumulator: &accumulator
                    )
                case "user":
                    try applyUser(
                        directive.arguments,
                        applicability: applicability,
                        accumulator: &accumulator
                    )
                case "port":
                    try applyPort(
                        directive.arguments,
                        applicability: applicability,
                        accumulator: &accumulator
                    )
                case "include":
                    try applyInclude(
                        directive.arguments,
                        argumentsContainedBackslash: directive.argumentsContainedBackslash,
                        includeBaseDirectoryURL: includeBaseDirectoryURL,
                        originalHost: originalHost,
                        depth: depth,
                        allowsHomeIncludeExpansion: allowsHomeIncludeExpansion,
                        applicability: &applicability,
                        accumulator: &accumulator,
                        activeFiles: &activeFiles,
                        loader: &loader
                    )
                case "canonicalizehostname":
                    try applyCanonicalization(
                        directive.arguments,
                        applicability: applicability,
                        accumulator: &accumulator
                    )
                default:
                    // Non-identity directives cannot alter this resolver's endpoint key.
                    continue
                }
            }
        } catch {
            activeFiles.remove(identity)
            throw error
        }
        activeFiles.remove(identity)
    }

    nonisolated private func applyHostName(
        _ arguments: [String],
        applicability: Applicability,
        accumulator: inout Accumulator
    ) throws {
        guard arguments.count == 1,
              !arguments[0].isEmpty,
              !containsUnsupportedToken(arguments[0]),
              let host = UniConnectSSHEffectiveTarget.normalizedHost(arguments[0]) else {
            throw ResolutionFailure.indeterminate
        }
        guard accumulator.hostName == nil else { return }
        switch applicability {
        case .no:
            return
        case .unknown:
            throw ResolutionFailure.indeterminate
        case .yes:
            accumulator.hostName = host
        }
    }

    nonisolated private func applyUser(
        _ arguments: [String],
        applicability: Applicability,
        accumulator: inout Accumulator
    ) throws {
        guard arguments.count == 1,
              !arguments[0].isEmpty,
              !containsUnsupportedToken(arguments[0]),
              let user = UniConnectSSHEffectiveTarget.normalizedUser(arguments[0]) else {
            throw ResolutionFailure.indeterminate
        }
        guard accumulator.user == nil else { return }
        switch applicability {
        case .no:
            return
        case .unknown:
            throw ResolutionFailure.indeterminate
        case .yes:
            accumulator.user = user
        }
    }

    nonisolated private func applyPort(
        _ arguments: [String],
        applicability: Applicability,
        accumulator: inout Accumulator
    ) throws {
        guard arguments.count == 1,
              !containsUnsupportedToken(arguments[0]),
              let port = Int(arguments[0]),
              (1...65_535).contains(port) else {
            throw ResolutionFailure.indeterminate
        }
        guard accumulator.port == nil else { return }
        switch applicability {
        case .no:
            return
        case .unknown:
            throw ResolutionFailure.indeterminate
        case .yes:
            accumulator.port = port
        }
    }

    nonisolated private func applyInclude(
        _ arguments: [String],
        argumentsContainedBackslash: Bool,
        includeBaseDirectoryURL: URL,
        originalHost: String,
        depth: Int,
        allowsHomeIncludeExpansion: Bool,
        applicability: inout Applicability,
        accumulator: inout Accumulator,
        activeFiles: inout Set<FileIdentity>,
        loader: inout FileLoader
    ) throws {
        guard !arguments.isEmpty else { throw ResolutionFailure.indeterminate }
        switch applicability {
        case .no:
            return
        case .unknown:
            // Whether the Include itself executes is dynamic. If any identity value
            // is still open, the included stream could supply its first value.
            guard accumulator.user != nil,
                  accumulator.hostName != nil,
                  accumulator.port != nil,
                  accumulator.canonicalizeHostname == false else {
                throw ResolutionFailure.indeterminate
            }
            return
        case .yes:
            break
        }
        guard !argumentsContainedBackslash else {
            throw ResolutionFailure.indeterminate
        }

        for pattern in arguments {
            let urls = try loader.expandInclude(
                pattern,
                relativeTo: includeBaseDirectoryURL,
                allowsHomeExpansion: allowsHomeIncludeExpansion
            )
            for url in urls {
                // OpenSSH isolates Host/Match applicability at every Include file
                // boundary. Identity values obtained inside the file survive, but a
                // stanza at its end must not deactivate the next included file or the
                // remainder of the parent file.
                var includedApplicability = applicability
                try interpret(
                    url,
                    includeBaseDirectoryURL: includeBaseDirectoryURL,
                    originalHost: originalHost,
                    depth: depth + 1,
                    allowsHomeIncludeExpansion: allowsHomeIncludeExpansion,
                    applicability: &includedApplicability,
                    accumulator: &accumulator,
                    activeFiles: &activeFiles,
                    loader: &loader
                )
            }
        }
    }

    nonisolated private func applyCanonicalization(
        _ arguments: [String],
        applicability: Applicability,
        accumulator: inout Accumulator
    ) throws {
        guard arguments.count == 1 else { throw ResolutionFailure.indeterminate }
        let enablesCanonicalization: Bool
        switch arguments[0].lowercased() {
        case "no", "false":
            enablesCanonicalization = false
        case "yes", "true", "always":
            enablesCanonicalization = true
        default:
            throw ResolutionFailure.indeterminate
        }
        guard accumulator.canonicalizeHostname == nil else { return }
        switch applicability {
        case .no:
            return
        case .unknown:
            guard !enablesCanonicalization else {
                throw ResolutionFailure.indeterminate
            }
            // Whether this `no` is applied cannot change the default disabled state.
            return
        case .yes:
            if enablesCanonicalization {
                // Supporting this would require DNS and OpenSSH's canonical/final pass.
                throw ResolutionFailure.indeterminate
            } else {
                accumulator.canonicalizeHostname = false
            }
        }
    }

    nonisolated private func hostApplicability(
        patterns: [String],
        originalHost: String,
        loader: inout FileLoader
    ) throws -> Bool {
        guard !patterns.isEmpty else { throw ResolutionFailure.indeterminate }
        var positiveMatch = false
        var sawPositive = false
        var patternBytes = 0
        for rawPattern in patterns {
            var pattern = rawPattern
            patternBytes += pattern.utf8.count
            guard patterns.count <= 256,
                  patternBytes <= 4_096,
                  !pattern.isEmpty,
                  !containsUnsupportedToken(pattern) else {
                throw ResolutionFailure.indeterminate
            }
            let negated = pattern.hasPrefix("!")
            if negated { pattern.removeFirst() }
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+,:-[]*?"
            )
            guard !pattern.isEmpty,
                  pattern.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ResolutionFailure.indeterminate
            }
            try loader.chargePatternWork(pattern: pattern, candidate: originalHost)
            let matched = FileLoader.wildcardMatch(
                pattern: pattern,
                candidate: originalHost,
                caseInsensitive: false
            )
            if negated, matched { return false }
            if !negated {
                sawPositive = true
                positiveMatch = positiveMatch || matched
            }
        }
        return sawPositive && positiveMatch
    }

    nonisolated private func matchApplicability(
        _ arguments: [String],
        originalHost: String,
        loader: inout FileLoader
    ) throws -> Applicability {
        guard !arguments.isEmpty else { throw ResolutionFailure.indeterminate }
        let first = arguments[0].lowercased()
        if first == "all" {
            guard arguments.count == 1 else { throw ResolutionFailure.indeterminate }
            return .yes
        }
        if first == "originalhost" {
            guard arguments.count > 1 else { throw ResolutionFailure.indeterminate }
            // One criterion consumes exactly one comma-separated pattern list. Any
            // additional token is another ANDed criterion whose runtime value this
            // inert resolver deliberately does not emulate.
            guard arguments.count == 2 else {
                return .unknown
            }
            return try matchOriginalHostPatternList(
                arguments[1],
                candidate: originalHost,
                loader: &loader
            ) ? .yes : .no
        }
        switch first {
        case "canonical", "final":
            guard arguments.count == 1 else { throw ResolutionFailure.indeterminate }
        case "command", "exec", "host", "localnetwork", "localuser", "sessiontype", "tagged", "user", "version":
            guard arguments.count > 1 else { throw ResolutionFailure.indeterminate }
        default:
            throw ResolutionFailure.indeterminate
        }
        // `exec` is data only: it is never passed to a shell or subprocess. Other
        // Match criteria depend on OpenSSH runtime/canonical passes, so their truth
        // value remains deliberately unknown.
        return .unknown
    }

    nonisolated private func matchOriginalHostPatternList(
        _ value: String,
        candidate: String,
        loader: inout FileLoader
    ) throws -> Bool {
        var positiveMatch = false
        var sawPositive = false
        var patternCount = 0
        var patternBytes = 0
        for rawPattern in value.split(separator: ",", omittingEmptySubsequences: false) {
            var pattern = String(rawPattern)
            patternCount += 1
            patternBytes += pattern.utf8.count
            guard patternCount <= 256, patternBytes <= 4_096 else {
                throw ResolutionFailure.indeterminate
            }
            guard !pattern.isEmpty,
                  !containsUnsupportedToken(pattern) else {
                throw ResolutionFailure.indeterminate
            }
            let negated = pattern.hasPrefix("!")
            if negated { pattern.removeFirst() }
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+:-[]*?"
            )
            guard !pattern.isEmpty,
                  pattern.utf8.count <= 1_022,
                  pattern.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ResolutionFailure.indeterminate
            }
            try loader.chargePatternWork(pattern: pattern, candidate: candidate)
            let matched = FileLoader.wildcardMatch(
                pattern: pattern.lowercased(),
                candidate: candidate.lowercased(),
                caseInsensitive: true
            )
            if negated, matched { return false }
            if !negated {
                sawPositive = true
                positiveMatch = positiveMatch || matched
            }
        }
        return sawPositive && positiveMatch
    }

    nonisolated private func normalizedOptionalUser(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let normalized = UniConnectSSHEffectiveTarget.normalizedUser(value) else {
            throw ResolutionFailure.indeterminate
        }
        return normalized
    }

    nonisolated private func normalizedOptionalHost(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let normalized = UniConnectSSHEffectiveTarget.normalizedHost(value) else {
            throw ResolutionFailure.indeterminate
        }
        return normalized
    }

    nonisolated private func containsUnsupportedToken(_ value: String) -> Bool {
        value.contains("%") || value.contains("$") || value.contains("\0")
    }

    nonisolated private static func passwdUserName() -> String? {
        guard let record = getpwuid(getuid()), let name = record.pointee.pw_name else {
            return nil
        }
        let value = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
