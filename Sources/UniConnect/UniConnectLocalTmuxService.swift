import CMUXAgentLaunch
import CmuxProcess
import CmuxControlSocket
import Darwin
import Foundation

/// Performs bounded, read-only tmux inspection away from the main actor.
actor UniConnectLocalTmuxService: UniConnectLocalTmuxInspecting {
    private let commands: any CommandRunning
    private let processEnvironment: @Sendable (Int) -> [String: String]?
    private let processIdentity: @Sendable (Int) -> UniConnectLocalTmuxProcessIdentity?
    private let isProcessDescendant: @Sendable (Int, Int) -> Bool
    private let processSnapshot: @Sendable () -> CmuxTopProcessSnapshot
    private let processArguments: @Sendable (Int) -> CmuxTopProcessArguments?
    private let isForegroundWithoutChildren: @Sendable (Int) -> Bool
    /// Claude's configuration folder when a process has no `CLAUDE_CONFIG_DIR` of its own.
    private let claudeConfigDirectory: URL
    /// A process's current folder, the agent's cwd when its session file or rollout has none.
    private let processDirectory: @Sendable (Int) -> String?

    init(
        commands: any CommandRunning,
        processEnvironment: @escaping @Sendable (Int) -> [String: String]?,
        processIdentity: @escaping @Sendable (Int) -> UniConnectLocalTmuxProcessIdentity? = {
            UniConnectLocalTmuxProcessIdentity(processID: $0)
        },
        isProcessDescendant: @escaping @Sendable (Int, Int) -> Bool = {
            guard let peer = pid_t(exactly: $0), let ancestor = pid_t(exactly: $1) else { return false }
            return SocketTransport().isProcessDescendant(peer, of: ancestor)
        },
        processSnapshot: @escaping @Sendable () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        },
        processArguments: @escaping @Sendable (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        isForegroundWithoutChildren: @escaping @Sendable (Int) -> Bool = {
            UniConnectLocalTmuxProcessIdentity.isForegroundWithoutChildren(processID: $0)
        },
        claudeConfigDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true),
        processDirectory: @escaping @Sendable (Int) -> String? = {
            UniConnectLocalTmuxService.currentDirectory(ofProcess: $0)
        }
    ) {
        self.commands = commands
        self.processEnvironment = processEnvironment
        self.processIdentity = processIdentity
        self.isProcessDescendant = isProcessDescendant
        self.processSnapshot = processSnapshot
        self.processArguments = processArguments
        self.isForegroundWithoutChildren = isForegroundWithoutChildren
        self.claudeConfigDirectory = claudeConfigDirectory
        self.processDirectory = processDirectory
    }

    func runtimeObservations(
        for targets: [UniConnectLocalTmuxRuntimeObservation.Target]
    ) async -> [UniConnectLocalTmuxRuntimeObservation] {
        guard !targets.isEmpty, !Task.isCancelled else { return [] }
        let processes = processSnapshot()
        var observations: [UniConnectLocalTmuxRuntimeObservation] = []
        for target in targets {
            guard !Task.isCancelled else { break }
            let owner = target.owner
            let arguments = [
                "-N", "-L", owner.binding.socketName, "display-message", "-p", "-t", "=" + owner.binding.name + ":",
                "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_current_path}\t#{pane_current_command}",
            ]
            guard let before = await commands.runStandardOutput(
                directory: "/", executable: "tmux", arguments: arguments, timeout: 2
            ), before.utf8.count <= 8_192 else { continue }
            let fields = before.trimmingCharacters(in: .newlines)
                .split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6, fields[0] == owner.binding.name, fields[1].hasPrefix("%"),
                  fields[3] == "0", let rootPID = Int(fields[2]),
                  let rootIdentity = processIdentity(rootPID) else { continue }
            let paneDirectory = String(fields[4])
            // #{pane_pid} is the pane's shell, not the agent: the agent is found in its subtree
            // with the shared agent-tree.v1 criterion (exactly one provider root).
            let first = await discoverAgent(rootPID: rootPID, processes: processes, paneDirectory: paneDirectory, openFiles: nil)
            let state: UniConnectLocalTmuxRuntimeObservation.State
            let peer: UniConnectLocalTmuxProcessIdentity
            switch first.outcome {
            case .found(let conversation):
                guard let identity = scopedAgentIdentity(pid: conversation.processID, owner: owner) else { continue }
                peer = identity
                state = .discovered(conversation)
            case .unidentified(let provider, let pid, let directory, _):
                guard let identity = scopedAgentIdentity(pid: pid, owner: owner) else { continue }
                peer = identity
                state = .unidentified(provider, workingDirectory: directory)
            case .ambiguous:
                peer = rootIdentity
                state = .ambiguous
            case .noAgent:
                guard let rootArguments = processArguments(rootPID),
                      Self.isShell(rootArguments.arguments.first), Self.isShell(String(fields[5])),
                      isForegroundWithoutChildren(rootPID) else { continue }
                peer = rootIdentity
                state = .shell
            }
            // Old panes can predate the root-shell integration environment. Their scoped agent
            // descendant may repair persistence, but never authorize socket input.
            let legacyGeneration: UUID?
            switch state {
            case .discovered, .unidentified:
                legacyGeneration = legacyRuntimePeerGeneration(root: rootIdentity, peer: peer, owner: owner)
            default:
                legacyGeneration = nil
            }
            if legacyGeneration == nil {
                guard await verifiedOwner(of: peer, among: [owner]) == owner else { continue }
            }
            guard let after = await commands.runStandardOutput(
                    directory: "/", executable: "tmux", arguments: arguments, timeout: 2
                  ), after == before, processIdentity(rootPID) == rootIdentity,
                  processIdentity(peer.pid) == peer, !Task.isCancelled else { continue }
            if let legacyGeneration {
                guard legacyRuntimePeerGeneration(root: rootIdentity, peer: peer, owner: owner) == legacyGeneration else { continue }
            }
            // exec preserves the PID/start timestamp: the identity is derived again from freshly
            // read argv and session files, and must be the same one.
            let second = await discoverAgent(
                rootPID: rootPID, processes: processes, paneDirectory: paneDirectory, openFiles: first.openFiles
            )
            guard Self.sameIdentity(first.outcome, second.outcome) else { continue }
            if case .shell = state {
                guard let live = processArguments(rootPID), Self.isShell(live.arguments.first),
                      isForegroundWithoutChildren(rootPID), processIdentity(rootPID) == rootIdentity else { continue }
            } else {
                guard processIdentity(peer.pid) == peer else { continue }
            }
            observations.append(.init(target: target, state: state))
        }
        return observations
    }

    /// The result of one discovery pass plus the open files it read, reused for re-derivation.
    private struct AgentDiscoveryPass {
        let outcome: AgentDiscoveryOutcome
        let openFiles: [Int: [String]]
    }

    /// Runs the shared criterion over the pane's subtree with live argv, uid and session files.
    private func discoverAgent(
        rootPID: Int,
        processes: CmuxTopProcessSnapshot,
        paneDirectory: String,
        openFiles knownOpenFiles: [Int: [String]]?
    ) async -> AgentDiscoveryPass {
        let discovery = AgentProcessDiscovery()
        var samples: [AgentProcessSample] = []
        var configDirectories: [Int: String] = [:]
        for pid in processes.expandedPIDs(rootPIDs: [rootPID]).sorted().prefix(discovery.maximumNodes * 2) {
            guard let info = processes.process(pid: pid) else { continue }
            let live = processArguments(pid)
            if let directory = live?.environment["CLAUDE_CONFIG_DIR"], directory.hasPrefix("/") {
                configDirectories[pid] = directory
            }
            samples.append(AgentProcessSample(
                pid: pid,
                parentPID: info.parentPID,
                userID: processIdentity(pid).map { Int($0.userID) } ?? -1,
                arguments: live?.arguments ?? []
            ))
        }
        // A session file only counts for a live process that already is Claude by the strict
        // criterion: a stale <pid>.json of a recycled pid (even `vim ~/.claude/CLAUDE.md`) says nothing.
        let liveClaude = Set(samples.filter {
            AgentObservedProvider.classify($0) == .claude
        }.map(\.pid))
        let defaultDirectory = claudeConfigDirectory
        let claudeSession: (Int) -> AgentClaudeSessionFile? = { pid in
            guard liveClaude.contains(pid) else { return nil }
            let root = configDirectories[pid].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
            return AgentClaudeSessionDirectory(root: root, isLiveClaude: { liveClaude.contains($0) }).file(pid: pid)
        }
        var openFiles = knownOpenFiles ?? [:]
        if knownOpenFiles == nil {
            let roots = discovery.providerRoots(rootPID: rootPID, processes: samples)
            if roots.count == 1, let root = roots.first, root.provider == .codex {
                // lsof only for the single Codex root and its own branch, never for every pane.
                for member in discovery.branch(of: root, processes: samples) {
                    openFiles[member.pid] = await codexRolloutPaths(pid: member.pid)
                }
            }
        }
        let outcome = discovery.discover(
            rootPID: rootPID,
            processes: samples,
            claudeSession: claudeSession,
            openFiles: openFiles,
            rolloutFirstLine: Self.firstLine(ofFileAt:),
            fallbackDirectory: paneDirectory.hasPrefix("/") ? paneDirectory : nil,
            processDirectory: { processDirectory($0) },
            resolvingPath: { AgentResumeWorkingDirectory().realPath($0) }
        )
        return AgentDiscoveryPass(outcome: outcome, openFiles: openFiles)
    }

    /// A process's current folder through `proc_pidinfo` (read-only, no subprocess).
    static func currentDirectory(ofProcess pid: Int) -> String? {
        guard let processID = pid_t(exactly: pid), processID > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.stride
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, Int32(expectedSize)) == expectedSize else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer -> String in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    /// The kernel identity of an agent root that carries this window's CMUX scope.
    private func scopedAgentIdentity(pid: Int, owner: UniConnectLocalTmuxOwner) -> UniConnectLocalTmuxProcessIdentity? {
        guard let live = processArguments(pid),
              live.matchesCMUXScope(workspaceId: owner.workspaceID, surfaceId: owner.panelID) else { return nil }
        return processIdentity(pid)
    }

    /// Codex rollout files one process holds open, read with `lsof -Fn` (read-only).
    private func codexRolloutPaths(pid: Int) async -> [String] {
        guard let output = await commands.runStandardOutput(
            directory: "/",
            executable: "/usr/sbin/lsof",
            arguments: ["-n", "-P", "-p", String(pid), "-Fn"],
            timeout: 2
        ), output.utf8.count <= 4 * 1_024 * 1_024 else { return [] }
        return output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("n"), line.contains("/.codex/sessions/") else { return nil }
            return String(line.dropFirst())
        }
    }

    /// Two passes agree when they name the same agent, conversation and root process.
    private static func sameIdentity(_ lhs: AgentDiscoveryOutcome, _ rhs: AgentDiscoveryOutcome) -> Bool {
        switch (lhs, rhs) {
        case let (.found(a), .found(b)):
            return a.provider == b.provider && a.sessionID == b.sessionID && a.processID == b.processID
        case let (.unidentified(a, pidA, _, _), .unidentified(b, pidB, _, _)):
            return a == b && pidA == pidB
        case (.ambiguous, .ambiguous), (.noAgent, .noAgent):
            return true
        default:
            return false
        }
    }

    /// The first line of a rollout, reading at most 64 KB.
    private static func firstLine(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: AgentClaudeSessionFile.maximumSize), !data.isEmpty else { return nil }
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first ?? data[...]
        return String(data: Data(line), encoding: .utf8)
    }

    /// Runtime-only compatibility for roots with no integration metadata whatsoever.
    /// Partial, empty, or conflicting values remain an ownership failure, not a legacy pane.
    private func legacyRuntimePeerGeneration(
        root: UniConnectLocalTmuxProcessIdentity,
        peer: UniConnectLocalTmuxProcessIdentity,
        owner: UniConnectLocalTmuxOwner
    ) -> UUID? {
        guard let rootEnvironment = processEnvironment(root.pid),
              ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "UNICONNECT_SURFACE_GENERATION"].allSatisfy({
                rootEnvironment[$0] == nil
              }), root.userID == peer.userID, root.pid != peer.pid,
              processIdentity(root.pid) == root, processIdentity(peer.pid) == peer,
              let peerEnvironment = processEnvironment(peer.pid),
              UUID(uuidString: peerEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: peerEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let generation = UUID(uuidString: peerEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? ""),
              isProcessDescendant(peer.pid, root.pid) else { return nil }
        return generation
    }

    private static func isShell(_ executable: String?) -> Bool {
        guard let executable else { return false }
        let name = (executable as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["sh", "bash", "zsh", "fish", "dash", "ksh"].contains(name)
    }

    func serverIsRunning(socketName: String) async -> Bool? {
        // -N: never start a server just to ask; list-sessions only reads.
        let result = await commands.run(
            directory: "/", executable: "tmux", arguments: ["-N", "-L", socketName, "list-sessions", "-F", "#{session_id}"],
            timeout: 2
        )
        guard result.executionError == nil, !result.timedOut, let status = result.exitStatus else { return nil }
        if status == 0 { return true }
        let error = (result.stderr ?? "").lowercased()
        if error.contains("no server running") || error.contains("error connecting") || error.contains("no such file") {
            return false
        }
        return nil
    }

    func liveIdentity(binding: UniConnectLocalTmuxBinding) async -> UniConnectLocalTmuxLiveIdentity? {
        // -N: never start a server just to read it; display-message only reads.
        let arguments = [
            "-N", "-L", binding.socketName, "display-message", "-p", "-t", "=" + binding.name + ":",
            "#{session_id}\t#{pane_id}",
        ]
        guard let output = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), output.utf8.count <= 256 else { return nil }
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2,
              fields[0].range(of: #"^\$[0-9]+$"#, options: .regularExpression) != nil,
              fields[1].range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return UniConnectLocalTmuxLiveIdentity(sessionID: String(fields[0]), paneID: String(fields[1]))
    }

    func generation(
        for binding: UniConnectLocalTmuxBinding,
        workspaceID: UUID,
        panelID: UUID
    ) async -> UUID? {
        let arguments = [
            "-L", binding.socketName, "display-message", "-p", "-t", "=" + binding.name + ":",
            "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}",
        ]
        guard let before = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ) else { return nil }
        let fields = before.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0].hasPrefix("$"), fields[1].hasPrefix("%"),
              fields[3] == "0", let pid = Int(fields[2]), pid > 1,
              let environment = processEnvironment(pid),
              UUID(uuidString: environment["CMUX_WORKSPACE_ID"] ?? "") == workspaceID,
              UUID(uuidString: environment["CMUX_SURFACE_ID"] ?? "") == panelID,
              let generation = UUID(uuidString: environment["UNICONNECT_SURFACE_GENERATION"] ?? "") else {
            return nil
        }
        // Neither a recycled PID nor a pane replaced during the environment read may grant
        // an old generation permission to mutate the newly attached terminal.
        guard let after = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), after == before,
              processEnvironment(pid)?["UNICONNECT_SURFACE_GENERATION"] == environment["UNICONNECT_SURFACE_GENERATION"] else {
            return nil
        }
        return generation
    }

    func verifiedOwner(
        of peer: UniConnectLocalTmuxProcessIdentity,
        among owners: [UniConnectLocalTmuxOwner]
    ) async -> UniConnectLocalTmuxOwner? {
        guard !Task.isCancelled, processIdentity(peer.pid) == peer,
              let peerEnvironment = processEnvironment(peer.pid),
              let workspaceID = UUID(uuidString: peerEnvironment["CMUX_WORKSPACE_ID"] ?? ""),
              let panelID = UUID(uuidString: peerEnvironment["CMUX_SURFACE_ID"] ?? "") else { return nil }
        // Environment is only an index into app-owned bindings, never an authorization claim.
        let candidates = owners.filter { $0.workspaceID == workspaceID && $0.panelID == panelID }
        guard candidates.count == 1, let owner = candidates.first else { return nil }
        let arguments = [
            "-N", "-L", owner.binding.socketName, "display-message", "-p", "-t", "=" + owner.binding.name + ":",
            "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{session_name}",
        ]
        guard let before = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), before.utf8.count <= 1_024 else { return nil }
        let fields = before.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0].hasPrefix("$"), fields[1].hasPrefix("%"),
              fields[3] == "0", fields[4] == owner.binding.name,
              let panePID = Int(fields[2]), panePID > 1,
              let paneIdentity = processIdentity(panePID), paneIdentity.userID == peer.userID,
              let paneEnvironment = processEnvironment(panePID),
              UUID(uuidString: paneEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: paneEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let paneGeneration = UUID(uuidString: paneEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? ""),
              processIdentity(peer.pid) == peer,
              (peer.pid == panePID || isProcessDescendant(peer.pid, panePID)) else { return nil }
        // The pane's original generation may predate a reattached Ghostty surface. Verify
        // that it is stable, not equal to the new surface generation in the model snapshot.
        guard let after = await commands.runStandardOutput(
            directory: "/", executable: "tmux", arguments: arguments, timeout: 2
        ), after == before, !Task.isCancelled,
              processIdentity(panePID) == paneIdentity,
              processIdentity(peer.pid) == peer,
              let finalEnvironment = processEnvironment(panePID),
              UUID(uuidString: finalEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: finalEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              UUID(uuidString: finalEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? "") == paneGeneration,
              (peer.pid == panePID || isProcessDescendant(peer.pid, panePID)) else { return nil }
        return owner
    }
}
