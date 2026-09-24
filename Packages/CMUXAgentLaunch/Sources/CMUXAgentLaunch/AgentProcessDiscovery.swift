import Foundation

/// Finds which agent a tmux pane runs, and on which conversation, from its process subtree.
///
/// This is the single detection criterion of `agent-tree.v1`, the same one Linux's
/// `agent_probe.py` and the VPS supervisor apply and that `contracts/agent-tree-v1/deteccion-casos.json`
/// pins down:
///
/// 1. The subtree is every descendant of `#{pane_pid}` (the pane's **shell**, not the agent),
///    walked breadth-first over a process table, at most ``maximumDepth`` levels and
///    ``maximumNodes`` processes. Inherited environment never adds a process from outside it.
/// 2. Each process is classified with ``AgentObservedProvider/classify(_:hasClaudeSession:)``.
/// 3. The roots are the agent processes without an agent ancestor inside the subtree: a Codex run
///    by Claude's Bash tool, or Codex's native binary under its `node` launcher, is not a root.
///    No root is ``AgentDiscoveryOutcome/noAgent``; two or more is ``AgentDiscoveryOutcome/ambiguous``.
/// 4. The identity of the single root comes from the first available source: Claude's session file,
///    the rollout a Codex process holds open, then the command line.
///
/// It is pure: the process table, session files, open files and rollout heads are passed in, so the
/// same fixture drives the tests on every platform.
///
/// ```swift
/// let outcome = AgentProcessDiscovery().discover(
///     rootPID: panePID,
///     processes: table,
///     claudeSession: { sessions.file(pid: $0) },
///     openFiles: [:],
///     rolloutFirstLine: { _ in nil },
///     fallbackDirectory: paneCurrentPath
/// )
/// ```
public struct AgentProcessDiscovery: Sendable {
    /// One agent process that has no agent ancestor in the pane's subtree.
    public struct ProviderRoot: Sendable, Equatable {
        /// The agent's root process.
        public let process: AgentProcessSample
        /// The agent it belongs to.
        public let provider: AgentObservedProvider
    }

    /// How many levels below the pane's shell are inspected.
    public let maximumDepth: Int
    /// How many processes of the subtree are inspected at most.
    public let maximumNodes: Int

    /// Creates a discovery with the contract's bounds.
    ///
    /// - Parameters:
    ///   - maximumDepth: Levels below the pane's shell; the contract uses 8.
    ///   - maximumNodes: Processes inspected at most; the contract uses 256.
    public init(maximumDepth: Int = 8, maximumNodes: Int = 256) {
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
    }

    /// The pane's process and its descendants, breadth-first and bounded.
    ///
    /// - Parameters:
    ///   - rootPID: The pane's `#{pane_pid}`.
    ///   - processes: The whole process table.
    /// - Returns: The root (when present in the table) followed by its descendants.
    public func subtree(rootPID: Int, processes: [AgentProcessSample]) -> [AgentProcessSample] {
        let byParent = Dictionary(grouping: processes, by: \.parentPID)
        var seen: Set<Int> = [rootPID]
        var result: [AgentProcessSample] = processes.first(where: { $0.pid == rootPID }).map { [$0] } ?? []
        var frontier = [rootPID]
        var depth = 0
        while !frontier.isEmpty, depth < maximumDepth, result.count < maximumNodes {
            depth += 1
            var next: [Int] = []
            for pid in frontier {
                for child in byParent[pid] ?? [] where child.pid != pid && result.count < maximumNodes {
                    guard seen.insert(child.pid).inserted else { continue }
                    result.append(child)
                    next.append(child.pid)
                }
            }
            frontier = next
        }
        return result
    }

    /// The agent roots of a pane: agent processes without an agent ancestor inside the subtree.
    ///
    /// - Parameters:
    ///   - rootPID: The pane's `#{pane_pid}`.
    ///   - processes: The whole process table.
    ///   - hasClaudeSession: Whether a live Claude session file exists for a pid.
    /// - Returns: The roots in breadth-first order.
    public func providerRoots(
        rootPID: Int,
        processes: [AgentProcessSample],
        hasClaudeSession: (Int) -> Bool
    ) -> [ProviderRoot] {
        let tree = subtree(rootPID: rootPID, processes: processes)
        let byPID = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var providers: [Int: AgentObservedProvider] = [:]
        for process in tree {
            if let provider = AgentObservedProvider.classify(process, hasClaudeSession: hasClaudeSession(process.pid)) {
                providers[process.pid] = provider
            }
        }
        return tree.compactMap { process in
            guard let provider = providers[process.pid] else { return nil }
            guard process.pid != rootPID else { return ProviderRoot(process: process, provider: provider) }
            var ancestorPID = process.parentPID
            var hops = 0
            while let ancestor = byPID[ancestorPID], hops <= maximumNodes {
                if providers[ancestor.pid] != nil { return nil }
                if ancestor.pid == rootPID { break }
                ancestorPID = ancestor.parentPID
                hops += 1
            }
            return ProviderRoot(process: process, provider: provider)
        }
    }

    /// The processes of the same agent below one root, the root included.
    ///
    /// Codex's rollout may be held by the native binary under the `node` launcher, so the whole
    /// branch is inspected, not only the root.
    ///
    /// - Parameters:
    ///   - root: An agent root from ``providerRoots(rootPID:processes:hasClaudeSession:)``.
    ///   - processes: The whole process table.
    /// - Returns: The root and every descendant classified as the same provider.
    public func branch(of root: ProviderRoot, processes: [AgentProcessSample]) -> [AgentProcessSample] {
        subtree(rootPID: root.process.pid, processes: processes).filter { process in
            process.pid == root.process.pid
                || AgentObservedProvider.classify(process, hasClaudeSession: false) == root.provider
        }
    }

    /// Decides which agent and conversation a pane runs.
    ///
    /// - Parameters:
    ///   - rootPID: The pane's `#{pane_pid}`.
    ///   - processes: The whole process table.
    ///   - claudeSession: The live session file of a Claude pid (see ``AgentClaudeSessionDirectory``).
    ///   - openFiles: Paths each pid holds open; only Codex processes need an entry.
    ///   - rolloutFirstLine: The first line (≤ 64 KB) of a rollout file, to read its `payload.cwd`.
    ///   - fallbackDirectory: `#{pane_current_path}`, used when no better folder is known.
    /// - Returns: The outcome; only ``AgentDiscoveryOutcome/found(_:)`` identifies a conversation.
    public func discover(
        rootPID: Int,
        processes: [AgentProcessSample],
        claudeSession: (Int) -> AgentClaudeSessionFile?,
        openFiles: [Int: [String]],
        rolloutFirstLine: (String) -> String?,
        fallbackDirectory: String?
    ) -> AgentDiscoveryOutcome {
        var sessionFiles: [Int: AgentClaudeSessionFile] = [:]
        let roots = providerRoots(rootPID: rootPID, processes: processes) { pid in
            guard let file = claudeSession(pid) else { return false }
            sessionFiles[pid] = file
            return true
        }
        guard !roots.isEmpty else { return .noAgent }
        guard roots.count == 1, let root = roots.first else { return .ambiguous }
        let process = root.process
        let asRoot = process.userID == 0
        func found(_ id: String, _ directory: String?, _ source: AgentObservedConversation.Source,
                   status: String? = nil, version: String? = nil) -> AgentDiscoveryOutcome {
            .found(AgentObservedConversation(
                provider: root.provider,
                sessionID: Self.normalizedID(id),
                workingDirectory: directory ?? fallbackDirectory,
                asRoot: asRoot,
                source: source,
                status: status,
                version: version,
                processID: process.pid
            ))
        }

        switch root.provider {
        case .claude:
            if let file = sessionFiles[process.pid] ?? claudeSession(process.pid) {
                return found(file.sessionId, file.cwd, .sessionFile, status: file.status, version: file.version)
            }
            if let id = Self.uniqueOptionValue(["--resume", "-r", "--session-id"], in: process.arguments, requireUUID: true) {
                return found(id, nil, .argv)
            }
        case .codex:
            let branch = branch(of: root, processes: processes)
            var rollouts: [String: String] = [:]
            for member in branch {
                for path in openFiles[member.pid] ?? [] {
                    if let id = Self.rolloutID(path: path) { rollouts[id] = path }
                }
            }
            if rollouts.count == 1, let rollout = rollouts.first {
                let directory = rolloutFirstLine(rollout.value).flatMap(Self.rolloutWorkingDirectory(firstLine:))
                return found(rollout.key, directory, .rollout)
            }
            for member in branch {
                if let id = Self.codexResumeID(member.arguments) { return found(id, nil, .argv) }
            }
        case .agy:
            if let id = Self.uniqueOptionValue(["--conversation"], in: process.arguments, requireUUID: false) {
                return found(id, nil, .argv)
            }
        case .grok:
            if let id = Self.uniqueOptionValue(["-r", "--resume"], in: process.arguments, requireUUID: false) {
                return found(id, nil, .argv)
            }
        }
        return .unidentified(root.provider, processID: process.pid)
    }

    /// The conversation id of a Codex rollout path, or `nil` when it is not one.
    ///
    /// - Parameter path: An open file, such as `~/.codex/sessions/2026/09/24/rollout-…-<uuid>.jsonl`.
    /// - Returns: The trailing UUID in lowercase.
    public static func rolloutID(path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard path.contains("/.codex/sessions/"), name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else {
            return nil
        }
        let stem = name.dropLast(".jsonl".count)
        guard stem.count > "rollout-".count + 36 else { return nil }
        let candidate = String(stem.suffix(36))
        guard stem.dropLast(36).hasSuffix("-"), UUID(uuidString: candidate) != nil else { return nil }
        return candidate.lowercased()
    }

    /// The `payload.cwd` of a rollout's first line, when present.
    ///
    /// - Parameter firstLine: The rollout's first JSON line.
    /// - Returns: The absolute folder Codex started in.
    public static func rolloutWorkingDirectory(firstLine: String) -> String? {
        guard firstLine.utf8.count <= AgentClaudeSessionFile.maximumSize,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        return cwd
    }

    private static func codexResumeID(_ arguments: [String]) -> String? {
        guard let index = arguments.dropFirst().firstIndex(of: "resume"),
              arguments.indices.contains(index + 1) else { return nil }
        let candidate = arguments[index + 1]
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// The single value given to any of `options`, or `nil` when there is none or they disagree.
    private static func uniqueOptionValue(_ options: [String], in arguments: [String], requireUUID: Bool) -> String? {
        var found: Set<String> = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            var value: String?
            if options.contains(argument), index + 1 < arguments.count {
                value = arguments[index + 1]
                index += 1
            } else if let option = options.first(where: { argument.hasPrefix($0 + "=") }) {
                value = String(argument.dropFirst(option.count + 1))
            }
            if let value {
                guard AgentNoPromptPolicy.isValidSessionID(value),
                      !requireUUID || UUID(uuidString: value) != nil else { return nil }
                found.insert(normalizedID(value))
            }
            index += 1
        }
        return found.count == 1 ? found.first : nil
    }

    private static func normalizedID(_ id: String) -> String {
        UUID(uuidString: id) != nil ? id.lowercased() : id
    }
}
