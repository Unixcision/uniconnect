import CMUXAgentLaunch
import Darwin
import Foundation

/// Closes a Claude in a local tmux pane and brings the same conversation back, keeping what it had.
///
/// The rules are `contracts/relaunch-v1/LEEME.md` («Escalado y mismas opciones», 08-11, and
/// «Actualizar Claude, monitores y borradores», 09-11), the same ones the Linux worker follows:
///
/// - **Identity** comes from `~/.claude/sessions/<pid>.json`, and only when its `startedAt` matches
///   the kernel's start of that very process (±2 s). Two live Claude on one conversation are both
///   left alone (`conversacion_compartida`).
/// - **Never `/exit` over a draft.** The composer is read with its styling (a dimmed suggestion is
///   empty, the person's own text is a draft). With a draft, or when it is working, the close goes
///   straight to stopping the agent's process group — never the pane's shell — and the draft is
///   written back, without return, after the conversation is verified.
/// - **Monitors** (its Bash wrappers) are saved before closing, their trees are stopped after it,
///   and the agent is told about them in the one message it gets; an idle agent without monitors
///   gets nothing typed into it.
/// - It reopens with the **same options** (allowlisted), through the stable launcher, with the
///   model and effort `agent.update` asked for, and answers the folder-trust question only by its
///   text and only for the folder the conversation already ran in.
struct UniConnectRelaunchLocalClaude: Sendable {
    /// What looking at a pane established.
    enum Inspection: Sendable, Equatable {
        /// A Claude that can be relaunched, and what the plan shows about it.
        case proof(UniConnectRelaunchLocalClaudeProof, RelaunchTargetNotes)
        /// Why this window is left alone.
        case excluded(RelaunchCause)
    }

    private let panes: any UniConnectRelaunchPaneAccess
    private let processes: any UniConnectRelaunchProcessInspecting
    private let archive: UniConnectRelaunchMonitorArchive
    private let home: URL
    private let directoryExists: @Sendable (String) -> Bool
    private let isExecutable: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    /// Waits for a terminal to repaint before the screen is read again. Injected so tests do not
    /// wait; tmux has no repaint signal for a pane we are not attached to, so this bounded,
    /// cancellable delay is the intended pause between two reads, never a settle for state.
    private let settle: @Sendable () async -> Void

    init(
        panes: any UniConnectRelaunchPaneAccess = UniConnectRelaunchTmuxDriver(),
        processes: any UniConnectRelaunchProcessInspecting = UniConnectRelaunchDarwinProcesses(),
        archive: UniConnectRelaunchMonitorArchive = UniConnectRelaunchMonitorArchive(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(600)) }
    ) {
        self.panes = panes
        self.processes = processes
        self.archive = archive
        self.home = home
        self.directoryExists = directoryExists
        self.isExecutable = isExecutable
        self.now = now
        self.settle = settle
    }

    // MARK: - Plan

    /// Looks at the Claude of one pane without touching it.
    func inspect(socket: String, session: String, verb: RelaunchVerb) async -> Inspection {
        guard let pane = await panes.firstPane(socket: socket, session: session),
              let shellPID = await panes.panePID(socket: socket, pane: pane),
              let table = processes.processes(),
              let shell = table.first(where: { $0.pid == shellPID }) else { return .excluded(.hostUnreachable) }
        let agent: UniConnectRelaunchProcessInfo
        switch locateAgent(under: shell, in: table) {
        case .none: return .excluded(.noAgent)
        case .ambiguous: return .excluded(.ambiguousIdentity)
        case let .found(found): agent = found
        }
        guard let arguments = processes.arguments(of: agent.pid) else { return .excluded(.ambiguousIdentity) }
        let configRoot = configRoot(environment: arguments.environment)
        guard let ficha = validFicha(of: agent, configRoot: configRoot) else { return .excluded(.ambiguousIdentity) }
        if sharesConversation(ficha.sessionId, with: agent, in: table) { return .excluded(.sharedConversation) }

        let status = ficha.status ?? ""
        var warning: RelaunchCause?
        switch status {
        case "idle": warning = nil
        case "busy", "shell": warning = .backgroundTasks
        case "waiting": warning = .permissions
        default: return .excluded(.unknownDialog)
        }
        let monitors = backgroundShells(of: agent, in: table)
        if warning == nil, !monitors.isEmpty { warning = .backgroundTasks }

        guard let screen = await panes.screen(socket: socket, pane: pane) else { return .excluded(.hostUnreachable) }
        if Self.showsTrustQuestion(screen.text) { return .excluded(.folderTrust) }
        var draft = false
        switch ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text) {
        case .draft: draft = true
        case .empty: break
        case .unrecognised:
            // Ociosa y sin compositor reconocible: no se sabe qué hay en pantalla.
            if status == "idle" { return .excluded(.unknownDialog) }
        }

        let directory = ficha.cwd ?? processes.workingDirectory(of: agent.pid) ?? ""
        guard !directory.isEmpty, directoryExists(directory) else { return .excluded(.missingFolder) }
        let executable = processes.executablePath(of: agent.pid)
        let launcher = ClaudeLaunchOptions.stableLauncher(argv0: arguments.argv.first ?? "", executable: executable)
        let launcherPath = resolve(launcher, path: arguments.environment["PATH"])
        guard launcherPath != nil else { return .excluded(.missingBinary) }
        let options = ClaudeLaunchOptions(argv: arguments.argv)
        let usage = ClaudeConversationUsage(contentsOf: ClaudeConversationUsage.transcriptURL(
            configRoot: configRoot, workingDirectory: directory, sessionID: ficha.sessionId
        ))
        let proof = UniConnectRelaunchLocalClaudeProof(
            pane: pane, shell: shell, agent: agent, argv: arguments.argv,
            sandboxed: arguments.environment["IS_SANDBOX"] == "1", workingDirectory: directory,
            sessionID: ficha.sessionId, status: status, searchPath: arguments.environment["PATH"], configRoot: configRoot,
            launcher: launcher, launcherPath: launcherPath, version: ficha.version
        )
        let notes = RelaunchTargetNotes(
            warning: warning,
            background: monitors.count,
            draft: draft,
            contextTokens: usage?.contextTokens,
            message: RelaunchReopenMessage.isNeeded(monitors: monitors.count, wasWorking: proof.wasWorking),
            version: verb == .agentUpdate ? ficha.version : nil,
            droppedOptions: options.dropped
        )
        return .proof(proof, notes)
    }

    // MARK: - Apply

    /// Closes and reopens the Claude `proof` describes.
    ///
    /// - Parameters:
    ///   - key: The target's key, for the result.
    ///   - socket: The tmux socket.
    ///   - session: The tmux session.
    ///   - proof: What the plan proved; anything that changed since is ``RelaunchCause/generationChanged``.
    ///   - verb: `agent.relaunch` or `agent.update`.
    ///   - options: `agent.update`'s model and effort.
    /// - Returns: Where it got to, with what was kept and how far the close had to escalate.
    func relaunch(
        key: RelaunchTargetKey,
        socket: String,
        session: String,
        proof: UniConnectRelaunchLocalClaudeProof,
        verb: RelaunchVerb,
        options: RelaunchUpdateOptions
    ) async -> RelaunchOperation.Result {
        func outcome(_ state: RelaunchTargetState, _ cause: RelaunchCause? = nil) -> RelaunchOperation.Result {
            .init(key: key, state: state, cause: cause, provider: "claude")
        }

        // 1. The same pane, the same process, the same conversation as the plan saw.
        guard await panes.firstPane(socket: socket, session: session) == proof.pane,
              let table = processes.processes(),
              let agent = table.first(where: { $0.pid == proof.agent.pid }), agent.isSameProcess(as: proof.agent),
              let ficha = validFicha(of: agent, configRoot: proof.configRoot),
              ficha.sessionId == proof.sessionID else { return outcome(.skipped, .generationChanged) }
        let wasWorking = ficha.status == "busy" || proof.wasWorking

        // 2. What has to survive: its monitors and its draft, read now, saved before closing.
        let monitors = backgroundShells(of: agent, in: table)
        guard let before = await panes.screen(socket: socket, pane: proof.pane) else { return outcome(.failed, .hostUnreachable) }
        if Self.showsTrustQuestion(before.text) { return outcome(.needsUser, .folderTrust) }
        let composer = ClaudeComposerReading.read(styledText: before.styledText ?? before.text)
        var draft: String?
        if case let .draft(text) = composer { draft = text }
        var monitorsFile: URL?
        if !monitors.isEmpty {
            let entries = monitors.map { UniConnectRelaunchMonitorArchive.Entry(
                shell: $0.shell, pid: $0.process.pid, workingDirectory: processes.workingDirectory(of: $0.process.pid)
            ) }
            guard let saved = try? archive.save(
                entries, sessionID: proof.sessionID, tmuxSession: session, status: ficha.status ?? proof.status, now: now()
            ) else {
                // Sin poder guardarlos no se cierra nada: se perderían.
                return outcome(.skipped, .unknownDialog)
            }
            monitorsFile = saved
        }

        // 3. Close: the clean exit only over an idle, empty composer; otherwise stop the process.
        var escalation = RelaunchEscalation.exit
        var closed = false
        if ficha.status == "idle", draft == nil, composer == .empty {
            switch await exitCleanly(socket: socket, proof: proof, agent: agent) {
            case .exited: closed = true
            case let .stop(cause): return outcome(.needsUser, cause)
            case .escalate: break
            }
        }
        if !closed {
            escalation = .killProcess
            guard await stop(agent, shell: proof.shell, table: table) else { return outcome(.failed, .unknownDialog) }
        }
        // Their whole trees, so a relaunched monitor does not run twice beside an orphan.
        await terminate(monitors.map { $0.process })

        // 4. A shell to type into: the pane's own, or a fresh login shell in the same pane.
        if await !waitForShell(socket: socket, pane: proof.pane) {
            guard await panes.respawnShell(socket: socket, pane: proof.pane, directory: proof.workingDirectory),
                  await waitForShell(socket: socket, pane: proof.pane) else {
                // Recrear la sesión mataría el cliente de escritorio enganchado a ella: aquí se para.
                return withEscalation(outcome(.failed, .unknownDialog), .respawnPane)
            }
            escalation = .respawnPane
        }

        // 5. Reopen with the same options, the stable launcher, and the requested model/effort.
        let launch = ClaudeLaunchOptions(argv: proof.argv).applying(verb == .agentUpdate ? options : .unchanged)
        let argv = launch.resumeArgv(launcher: proof.launcher, conversation: proof.sessionID)
        let line = "cd " + RelaunchShellWords.quote(proof.workingDirectory) + " && "
            + (proof.sandboxed ? "IS_SANDBOX=1 " : "") + RelaunchShellWords.join(argv)
        await panes.type(socket: socket, pane: proof.pane, text: line)

        // 6. Verified: a new process, on the same conversation, at an empty composer.
        var result = outcome(.failed, .unknownDialog)
        result.escalation = escalation
        result.droppedOptions = launch.dropped
        result.backgroundSaved = monitors.count
        result.model = launch.value(of: "--model")
        result.effort = launch.value(of: "--effort")
        guard let reopened = await waitForReopen(socket: socket, proof: proof) else { return result }
        switch reopened {
        case let .stopped(cause):
            return withDetails(result, state: .needsUser, cause: cause)
        case let .ready(version):
            result = withDetails(result, state: .verified, cause: nil, effectiveID: proof.sessionID)
            result.version = version
            // 7. The one message, only when it is needed, and then the draft, without return.
            let reason: RelaunchReopenMessage.Reason = verb == .agentUpdate
                ? .update(version: version ?? proof.version ?? "")
                : .relaunch
            if let message = RelaunchReopenMessage(
                reason: reason, monitors: monitors.count, monitorsFile: monitorsFile?.path, wasWorking: wasWorking
            ) {
                result.messageSent = await submit(message.text, socket: socket, pane: proof.pane)
            } else {
                result.messageSent = false
            }
            if let draft {
                result.draftRestored = await writeBack(draft, socket: socket, pane: proof.pane)
            } else {
                result.draftRestored = false
            }
            return result
        }
    }

    // MARK: - Steps

    private enum CleanExit {
        case exited
        case stop(RelaunchCause)
        case escalate
    }

    /// `/exit` typed literally, seen on the composer, then return, then up to 60 s for the process
    /// to end. «Exit and stop tasks» is chosen by its text; anything else escalates.
    private func exitCleanly(socket: String, proof: UniConnectRelaunchLocalClaudeProof, agent: UniConnectRelaunchProcessInfo) async -> CleanExit {
        await panes.typeLiteral(socket: socket, pane: proof.pane, text: "/exit")
        var shown = false
        for _ in 0..<10 {
            await settle()
            if let screen = await panes.screen(socket: socket, pane: proof.pane),
               ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text) == .draft("/exit") {
                shown = true
                break
            }
        }
        guard shown, let table = processes.processes(),
              table.contains(where: { $0.isSameProcess(as: agent) }) else { return .escalate }
        await panes.pressEnter(socket: socket, pane: proof.pane)
        var answered = false
        for _ in 0..<60 {
            if await processes.waitForExit(of: agent.pid, timeout: .seconds(1)) { return .exited }
            guard let screen = await panes.screen(socket: socket, pane: proof.pane) else { continue }
            if Self.showsTrustQuestion(screen.text) { return .stop(.folderTrust) }
            if !answered, ClaudeMenuReading(screen: screen.text, offering: "Exit and stop tasks") != nil {
                answered = true
                guard await choose("Exit and stop tasks", socket: socket, pane: proof.pane) else { return .escalate }
                continue
            }
            // On this Mac a recent /exit may leave the process alive in the background: the pane
            // is back at its shell and the agent did not die. That is not a close.
            if await panes.isAtShell(socket: socket, pane: proof.pane) { return .escalate }
        }
        return .escalate
    }

    /// SIGTERM to the agent's process group (or its own tree when it shares the shell's group),
    /// 5 s, then SIGKILL. Never the pane's shell.
    private func stop(_ agent: UniConnectRelaunchProcessInfo, shell: UniConnectRelaunchProcessInfo, table: [UniConnectRelaunchProcessInfo]) async -> Bool {
        let ownGroup = Int32(getpgrp())
        let byGroup = agent.group == agent.pid && agent.group != shell.group && agent.group != ownGroup && agent.group > 1
        let tree = [agent] + descendants(of: agent.pid, in: table)
        for signal in [SIGTERM, SIGKILL] {
            if byGroup {
                processes.signal(signal, toGroup: agent.group)
            } else {
                // Never the pane's shell, unless the agent itself is the pane's root (an `exec`).
                for process in tree where (process.pid != shell.pid || shell.pid == agent.pid) && isStillAlive(process) {
                    processes.signal(signal, to: process.pid)
                }
            }
            if await processes.waitForExit(of: agent.pid, timeout: signal == SIGTERM ? .seconds(5) : .seconds(2)) {
                return true
            }
        }
        return false
    }

    /// Stops the trees of the saved monitors, checking each start time so a reused pid is spared.
    private func terminate(_ roots: [UniConnectRelaunchProcessInfo]) async {
        guard !roots.isEmpty, let table = processes.processes() else { return }
        let tree = roots.flatMap { [$0] + descendants(of: $0.pid, in: table) }
        for signal in [SIGTERM, SIGKILL] {
            let alive = tree.filter(isStillAlive)
            guard !alive.isEmpty else { return }
            for process in alive { processes.signal(signal, to: process.pid) }
            for process in alive {
                _ = await processes.waitForExit(of: process.pid, timeout: signal == SIGTERM ? .seconds(5) : .seconds(1))
            }
        }
    }

    private func isStillAlive(_ process: UniConnectRelaunchProcessInfo) -> Bool {
        processes.processes()?.contains(where: { $0.isSameProcess(as: process) }) ?? false
    }

    /// Whether the pane is back at a shell with nothing of the agent left under it.
    private func waitForShell(socket: String, pane: String) async -> Bool {
        for _ in 0..<10 {
            if await panes.isAtShell(socket: socket, pane: pane),
               let shellPID = await panes.panePID(socket: socket, pane: pane),
               let table = processes.processes(),
               !table.contains(where: { $0.parent == shellPID }) {
                return true
            }
            await settle()
        }
        return false
    }

    private enum Reopened {
        case ready(version: String?)
        case stopped(RelaunchCause)
    }

    /// Up to about a minute for a new Claude on the same conversation at an empty composer.
    private func waitForReopen(socket: String, proof: UniConnectRelaunchLocalClaudeProof) async -> Reopened? {
        var trustAnswered = false
        var identity: AgentClaudeSessionFile?
        for _ in 0..<90 {
            await settle()
            guard let screen = await panes.screen(socket: socket, pane: proof.pane) else { continue }
            if Self.showsTrustQuestion(screen.text) {
                // Solo la carpeta donde ya corría esta conversación, y solo una vez.
                guard !trustAnswered, screen.text.contains(proof.workingDirectory) else { return .stopped(.folderTrust) }
                trustAnswered = true
                guard await choose("Yes, I trust this folder", socket: socket, pane: proof.pane) else {
                    return .stopped(.folderTrust)
                }
                continue
            }
            if identity == nil {
                guard let shellPID = await panes.panePID(socket: socket, pane: proof.pane),
                      let table = processes.processes(),
                      let shell = table.first(where: { $0.pid == shellPID }),
                      case let .found(agent) = locateAgent(under: shell, in: table),
                      !agent.isSameProcess(as: proof.agent),
                      let ficha = validFicha(of: agent, configRoot: proof.configRoot) else { continue }
                guard ficha.sessionId == proof.sessionID else { return .stopped(.ambiguousIdentity) }
                identity = ficha
            }
            if ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text) == .empty {
                return .ready(version: identity?.version)
            }
        }
        return identity == nil ? nil : .stopped(.unknownDialog)
    }

    /// Types `text` into an empty composer, checks it is there, and submits it.
    private func submit(_ text: String, socket: String, pane: String) async -> Bool {
        await panes.typeLiteral(socket: socket, pane: pane, text: text)
        let start = String(text.prefix(24))
        for _ in 0..<10 {
            await settle()
            guard let screen = await panes.screen(socket: socket, pane: pane),
                  case let .draft(shown) = ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text) else { continue }
            guard shown.replacingOccurrences(of: "\n", with: "").hasPrefix(start) else { return false }
            await panes.pressEnter(socket: socket, pane: pane)
            for _ in 0..<10 {
                await settle()
                if let after = await panes.screen(socket: socket, pane: pane),
                   ClaudeComposerReading.read(styledText: after.styledText ?? after.text) != .draft(shown) {
                    return true
                }
            }
            return true
        }
        return false
    }

    /// Writes the saved draft back without return. Line breaks become spaces: a typed newline
    /// would submit it, which is exactly what must never happen to a draft.
    private func writeBack(_ draft: String, socket: String, pane: String) async -> Bool {
        let text = draft.replacingOccurrences(of: "\n", with: " ")
        for _ in 0..<20 {
            if let screen = await panes.screen(socket: socket, pane: pane),
               ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text) == .empty { break }
            await settle()
        }
        await panes.typeLiteral(socket: socket, pane: pane, text: text)
        for _ in 0..<6 {
            await settle()
            if let screen = await panes.screen(socket: socket, pane: pane),
               case let .draft(shown) = ClaudeComposerReading.read(styledText: screen.styledText ?? screen.text),
               shown.replacingOccurrences(of: "\n", with: "").contains(String(text.suffix(16))) {
                return true
            }
        }
        return false
    }

    /// Moves the menu marker to `option` by its text and presses Enter only once it is there.
    private func choose(_ option: String, socket: String, pane: String) async -> Bool {
        for _ in 0..<3 {
            guard let screen = await panes.screen(socket: socket, pane: pane),
                  let menu = ClaudeMenuReading(screen: screen.text, offering: option),
                  let moves = menu.moves(to: option) else { return false }
            if moves == 0 {
                await panes.pressEnter(socket: socket, pane: pane)
                return true
            }
            for _ in 0..<abs(moves) {
                await panes.pressKey(socket: socket, pane: pane, key: moves > 0 ? "Down" : "Up")
            }
            await settle()
        }
        return false
    }

    // MARK: - Reading

    private enum AgentLookup {
        case none
        case ambiguous
        case found(UniConnectRelaunchProcessInfo)
    }

    /// The one Claude under the pane's shell (the shell itself counts, for an `exec`).
    private func locateAgent(under shell: UniConnectRelaunchProcessInfo, in table: [UniConnectRelaunchProcessInfo]) -> AgentLookup {
        let subtree = [shell] + descendants(of: shell.pid, in: table)
        let claudes = subtree.filter(isClaude)
        let pids = Set(claudes.map(\.pid))
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // The root ones: a Claude launched by another Claude (in a monitor) is not the agent.
        let roots = claudes.filter { candidate in
            var parent = candidate.parent
            while parent > 1, parent != shell.pid, let process = byPID[parent] {
                if pids.contains(parent) { return false }
                parent = process.parent
            }
            return true
        }
        switch roots.count {
        case 0: return .none
        case 1: return .found(roots[0])
        default: return .ambiguous
        }
    }

    private func isClaude(_ process: UniConnectRelaunchProcessInfo) -> Bool {
        let executable = processes.executablePath(of: process.pid) ?? ""
        let named = process.name == "claude" || (executable as NSString).lastPathComponent == "claude"
            || (executable as NSString).lastPathComponent == "claude.exe" || executable.contains("/claude/versions/")
        guard named, let argv = processes.arguments(of: process.pid)?.argv else { return false }
        // The Chrome bridge and `claude mcp …` are Claude programs, not an agent in a pane.
        return !argv.contains("--chrome-native-host") && argv.dropFirst().first != "mcp"
    }

    private func descendants(of pid: Int32, in table: [UniConnectRelaunchProcessInfo]) -> [UniConnectRelaunchProcessInfo] {
        var children: [Int32: [UniConnectRelaunchProcessInfo]] = [:]
        for process in table { children[process.parent, default: []].append(process) }
        var result: [UniConnectRelaunchProcessInfo] = []
        var frontier = children[pid] ?? []
        var seen: Set<Int32> = [pid]
        while let next = frontier.popLast() {
            guard seen.insert(next.pid).inserted else { continue }
            result.append(next)
            frontier.append(contentsOf: children[next.pid] ?? [])
        }
        return result
    }

    /// The direct children of the agent that are its Bash wrappers, with their commands.
    private func backgroundShells(of agent: UniConnectRelaunchProcessInfo, in table: [UniConnectRelaunchProcessInfo]) -> [(process: UniConnectRelaunchProcessInfo, shell: ClaudeBackgroundShell)] {
        table.filter { $0.parent == agent.pid }
            .sorted { $0.start < $1.start }
            .compactMap { process in
                guard let argv = processes.arguments(of: process.pid)?.argv,
                      let shell = ClaudeBackgroundShell(argv: argv) else { return nil }
                return (process, shell)
            }
    }

    private func configRoot(environment: [String: String]) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The session file of this very process: its pid inside, and its start within 2 s.
    private func validFicha(of agent: UniConnectRelaunchProcessInfo, configRoot: URL) -> AgentClaudeSessionFile? {
        let url = configRoot.appendingPathComponent("sessions/\(agent.pid).json", isDirectory: false)
        guard let file = AgentClaudeSessionFile.read(at: url), file.belongs(toProcess: Int(agent.pid)),
              file.matchesProcessStart(agent.start) else { return nil }
        return file
    }

    /// Whether another live Claude of the same user has the same conversation open.
    private func sharesConversation(_ sessionID: String, with agent: UniConnectRelaunchProcessInfo, in table: [UniConnectRelaunchProcessInfo]) -> Bool {
        table.contains { other in
            guard other.pid != agent.pid, other.userID == agent.userID, isClaude(other) else { return false }
            let root = processes.arguments(of: other.pid).map { configRoot(environment: $0.environment) }
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            return validFicha(of: other, configRoot: root)?.sessionId.lowercased() == sessionID.lowercased()
        }
    }

    /// The absolute path a launcher resolves to in the agent's own `PATH`.
    private func resolve(_ launcher: String, path: String?) -> String? {
        if launcher.hasPrefix("/") { return isExecutable(launcher) ? launcher : nil }
        let directories = (path ?? "").split(separator: ":").map(String.init)
            + ["\(home.path)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        return directories.lazy
            .map { ($0 as NSString).appendingPathComponent(launcher) }
            .first { isExecutable($0) }
    }

    /// Claude's folder-trust question.
    static func showsTrustQuestion(_ text: String) -> Bool {
        text.contains("Yes, I trust this folder") || text.lowercased().contains("do you trust the files in this folder")
    }

    private func withEscalation(_ result: RelaunchOperation.Result, _ escalation: RelaunchEscalation) -> RelaunchOperation.Result {
        var copy = result
        copy.escalation = escalation
        return copy
    }

    private func withDetails(
        _ result: RelaunchOperation.Result,
        state: RelaunchTargetState,
        cause: RelaunchCause?,
        effectiveID: String? = nil
    ) -> RelaunchOperation.Result {
        var copy = RelaunchOperation.Result(key: result.key, state: state, cause: cause, effectiveID: effectiveID, provider: "claude")
        copy.escalation = result.escalation
        copy.droppedOptions = result.droppedOptions
        copy.version = result.version
        copy.model = result.model
        copy.effort = result.effort
        copy.backgroundSaved = result.backgroundSaved
        copy.messageSent = result.messageSent
        copy.draftRestored = result.draftRestored
        return copy
    }
}
