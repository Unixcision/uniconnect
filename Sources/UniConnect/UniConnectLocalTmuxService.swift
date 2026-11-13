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
        let sockets = Set(targets.map { $0.owner.binding.socketName })
        let before = await paneSnapshots(sockets: sockets)
        let processes = processSnapshot()
        var pending: [(target: UniConnectLocalTmuxRuntimeObservation.Target,
                       pane: UniConnectLocalTmuxPaneSnapshot,
                       root: UniConnectLocalTmuxProcessIdentity,
                       peer: UniConnectLocalTmuxProcessIdentity,
                       state: UniConnectLocalTmuxRuntimeObservation.State,
                       first: AgentDiscoveryPass, generation: UUID?, legacy: UUID?)] = []
        for target in targets {
            guard !Task.isCancelled else { return [] }
            let owner = target.owner
            guard let pane = before[owner.binding.socketName]?[owner.binding.name],
                  let rootIdentity = processIdentity(pane.processID) else { continue }
            let first = await discoverAgent(rootPID: pane.processID, processes: processes,
                                            paneDirectory: pane.directory, openFiles: nil)
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
                guard let rootArguments = processArguments(pane.processID),
                      Self.isShell(rootArguments.arguments.first), Self.isShell(pane.command),
                      isForegroundWithoutChildren(pane.processID) else { continue }
                peer = rootIdentity
                state = .shell
            }
            let legacy: UUID?
            switch state {
            case .discovered, .unidentified:
                legacy = await legacyRuntimePeerGeneration(root: rootIdentity, peer: peer, owner: owner)
            default: legacy = nil
            }
            let generation = legacy == nil
                ? await runtimeGeneration(root: rootIdentity, peer: peer, owner: owner) : nil
            guard legacy != nil || generation != nil else { continue }
            pending.append((target, pane, rootIdentity, peer, state, first, generation, legacy))
        }
        // Two socket-wide reads bracket discovery. Reusing an old read as the final check would
        // miss a replaced pane/session; input authorization keeps its independent strict path.
        let after = await paneSnapshots(sockets: sockets)
        var observations: [UniConnectLocalTmuxRuntimeObservation] = []
        for item in pending {
            let owner = item.target.owner
            guard !Task.isCancelled,
                  after[owner.binding.socketName]?[owner.binding.name] == item.pane,
                  processIdentity(item.root.pid) == item.root,
                  processIdentity(item.peer.pid) == item.peer else { continue }
            if let legacy = item.legacy {
                guard await legacyRuntimePeerGeneration(root: item.root, peer: item.peer, owner: owner) == legacy else { continue }
            } else {
                guard await runtimeGeneration(root: item.root, peer: item.peer, owner: owner) == item.generation else { continue }
            }
            // exec can keep PID/start time: re-read argv and native identity files, not just PIDs.
            let second = await discoverAgent(rootPID: item.root.pid, processes: processes,
                paneDirectory: item.pane.directory, openFiles: item.first.openFiles)
            guard Self.sameIdentity(item.first.outcome, second.outcome),
                  processIdentity(item.root.pid) == item.root,
                  processIdentity(item.peer.pid) == item.peer else { continue }
            if case .shell = item.state {
                guard let live = processArguments(item.root.pid), Self.isShell(live.arguments.first),
                      isForegroundWithoutChildren(item.root.pid) else { continue }
            }
            observations.append(.init(target: item.target, state: item.state))
        }
        return observations
    }

    private func paneSnapshots(sockets: Set<String>) async -> [String: [String: UniConnectLocalTmuxPaneSnapshot]] {
        var result: [String: [String: UniConnectLocalTmuxPaneSnapshot]] = [:]
        for socket in sockets.sorted() {
            guard !Task.isCancelled else { break }
            if let output = await commands.runStandardOutput(directory: "/", executable: "tmux",
                arguments: ["-N", "-L", socket, "list-panes", "-a", "-F", UniConnectLocalTmuxPaneSnapshot.format], timeout: 2) {
                result[socket] = UniConnectLocalTmuxPaneSnapshot.parse(output)
            }
        }
        return result
    }

    /// Validates ownership against the captured pane; the caller brackets this with fresh tmux
    /// reads and kernel identity checks. Never used to authorize input to a terminal.
    private func runtimeGeneration(root: UniConnectLocalTmuxProcessIdentity,
                                   peer: UniConnectLocalTmuxProcessIdentity,
                                   owner: UniConnectLocalTmuxOwner) async -> UUID? {
        guard root.userID == peer.userID, processIdentity(root.pid) == root,
              processIdentity(peer.pid) == peer,
              let peerEnvironment = processEnvironment(peer.pid),
              UUID(uuidString: peerEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: peerEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let environment = await paneIdentityEnvironment(panePID: root.pid, binding: owner.binding),
              UUID(uuidString: environment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: environment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let generation = UUID(uuidString: environment["UNICONNECT_SURFACE_GENERATION"] ?? ""),
              peer.pid == root.pid || isProcessDescendant(peer.pid, root.pid) else { return nil }
        return generation
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
            let identity = processIdentity(pid)
            samples.append(AgentProcessSample(
                pid: pid,
                parentPID: info.parentPID,
                userID: identity.map { Int($0.userID) } ?? -1,
                arguments: live?.arguments ?? [],
                startMilliseconds: identity.map(Self.startMilliseconds)
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
        let roots = discovery.providerRoots(rootPID: rootPID, processes: samples)
        var codexHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
        if roots.count == 1, let root = roots.first, root.provider == .codex {
            // Codex 0.166+ no deja su rollout abierto: su conversación sale de la tabla threads, y
            // para eso hace falta ver los demás Codex vivos de este usuario (fuera de este panel).
            let inPane = Set(samples.map(\.pid))
            for info in processes.processesByPID.values where !inPane.contains(info.pid) && info.name.hasPrefix("codex") {
                guard let identity = processIdentity(info.pid), let live = processArguments(info.pid) else { continue }
                samples.append(AgentProcessSample(
                    pid: info.pid, parentPID: info.parentPID, userID: Int(identity.userID),
                    arguments: live.arguments, startMilliseconds: Self.startMilliseconds(identity)
                ))
            }
            if let custom = processArguments(root.process.pid)?.environment["CODEX_HOME"], custom.hasPrefix("/") {
                codexHome = URL(fileURLWithPath: custom, isDirectory: true)
            }
        }
        if knownOpenFiles == nil {
            if roots.count == 1, let root = roots.first, root.provider == .codex {
                // lsof only for the single Codex root and its own branch, never for every pane.
                openFiles = await codexRolloutPaths(pids: discovery.branch(of: root, processes: samples).map(\.pid))
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
            resolvingPath: { AgentResumeWorkingDirectory().realPath($0) },
            codexThreads: { AgentCodexThreadStore(codexHome: codexHome).threads(workingDirectories: $0) }
        )
        return AgentDiscoveryPass(outcome: outcome, openFiles: openFiles)
    }

    /// When a process started, in milliseconds since 1970, from its kernel record.
    static func startMilliseconds(_ identity: UniConnectLocalTmuxProcessIdentity) -> Int64 {
        Int64(identity.startSeconds) * 1_000 + Int64(identity.startMicroseconds / 1_000)
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

    /// One lsof invocation for the Codex branch, retaining each file's owning process.
    private func codexRolloutPaths(pids: [Int]) async -> [Int: [String]] {
        guard !pids.isEmpty else { return [:] }
        let allowed = Set(pids)
        var paths = Dictionary(uniqueKeysWithValues: allowed.map { ($0, [String]()) })
        guard let output = await commands.runStandardOutput(
            directory: "/", executable: "/usr/sbin/lsof",
            arguments: ["-n", "-P", "-p", allowed.sorted().map(String.init).joined(separator: ","), "-Fpn"],
            timeout: 2
        ), output.utf8.count <= 4 * 1_024 * 1_024 else { return paths }
        var pid: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int(line.dropFirst()).flatMap { allowed.contains($0) ? $0 : nil }
            } else if let pid, line.hasPrefix("n"), line.contains("/.codex/sessions/") {
                paths[pid, default: []].append(String(line.dropFirst()))
            }
        }
        return paths
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
    ) async -> UUID? {
        guard let rootEnvironment = processEnvironment(root.pid),
              ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "UNICONNECT_SURFACE_GENERATION"].allSatisfy({
                rootEnvironment[$0] == nil
              }), await sessionIdentityEnvironment(binding: owner.binding).isEmpty,
              root.userID == peer.userID, root.pid != peer.pid,
              processIdentity(root.pid) == root, processIdentity(peer.pid) == peer,
              let peerEnvironment = processEnvironment(peer.pid),
              UUID(uuidString: peerEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: peerEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              let generation = UUID(uuidString: peerEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? ""),
              isProcessDescendant(peer.pid, root.pid) else { return nil }
        return generation
    }

    /// The pane's UniConnect identity (workspace, surface and generation) for ownership checks.
    ///
    /// The pane root's own environment is used when it can be read. macOS 27 no longer exposes the
    /// environment of Apple's shells (`/bin/zsh`, `/bin/sh`, `/bin/bash`) through KERN_PROCARGS2, and
    /// every pane root is one of them, so the identity then comes from the tmux session environment
    /// UniConnect set when it created the session (`new-session -e`). A readable root that names
    /// another owner is never overridden by tmux.
    private func paneIdentityEnvironment(
        panePID: Int,
        binding: UniConnectLocalTmuxBinding
    ) async -> [String: String]? {
        if let environment = processEnvironment(panePID), environment["CMUX_SURFACE_ID"] != nil {
            return environment
        }
        let session = await sessionIdentityEnvironment(binding: binding)
        return session.isEmpty ? nil : session
    }

    /// Identity variables of one exact tmux session, read-only; never the server's global environment.
    private func sessionIdentityEnvironment(binding: UniConnectLocalTmuxBinding) async -> [String: String] {
        let keys: Set<String> = ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "UNICONNECT_SURFACE_GENERATION"]
        guard let output = await commands.runStandardOutput(
            directory: "/", executable: "tmux",
            arguments: ["-N", "-L", binding.socketName, "show-environment", "-t", "=" + binding.name],
            timeout: 2
        ), output.utf8.count <= 65_536 else { return [:] }
        var environment: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, keys.contains(String(pair[0])) else { continue }
            environment[String(pair[0])] = String(pair[1])
        }
        return environment
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
              let environment = await paneIdentityEnvironment(panePID: pid, binding: binding),
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
              await paneIdentityEnvironment(panePID: pid, binding: binding)?["UNICONNECT_SURFACE_GENERATION"]
                == environment["UNICONNECT_SURFACE_GENERATION"] else {
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
              let paneEnvironment = await paneIdentityEnvironment(panePID: panePID, binding: owner.binding),
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
              let finalEnvironment = await paneIdentityEnvironment(panePID: panePID, binding: owner.binding),
              UUID(uuidString: finalEnvironment["CMUX_WORKSPACE_ID"] ?? "") == owner.workspaceID,
              UUID(uuidString: finalEnvironment["CMUX_SURFACE_ID"] ?? "") == owner.panelID,
              UUID(uuidString: finalEnvironment["UNICONNECT_SURFACE_GENERATION"] ?? "") == paneGeneration,
              (peer.pid == panePID || isProcessDescendant(peer.pid, panePID)) else { return nil }
        return owner
    }
}
