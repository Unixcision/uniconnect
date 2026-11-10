import Foundation

/// Reads every open window's agent account now (`accounts-v1`), one probe per host, in parallel.
///
/// Runs the shared `agent_probe.py --accounts`: locally with `/usr/bin/python3` against each
/// UniConnect tmux socket, and on SSH boxes through the same pinned invocation as every other
/// remote probe (`python3 -`, script on stdin, 10 s). Nothing is cached between readings: a
/// reading that arrives while another runs shares that one. Only the usage history persists.
actor UniConnectAccountsReader {
    typealias CredentialResolver = @Sendable (UUID) async -> UniConnectSSHCredentialRecord?

    private struct Job: Sendable {
        enum Target: Sendable {
            case local(socket: String)
            case ssh(credentialID: UUID)
        }

        let id: String
        let hostKey: String
        let target: Target
        let sessions: [String]
        /// The probe's mode: `--accounts`, or `--codex-reset <key>` for §5.
        var mode: [String] = ["--accounts"]
    }

    /// What spending a Codex reset did (`accounts-v1` §5).
    struct CodexResetResult: Sendable {
        /// `reset`, `nothingToReset`, `noCredit` or `alreadyRedeemed`.
        let outcome: String
        let usage: UniConnectAccountsSnapshot.Usage?
    }

    /// Spends one free Codex reset of the account running in `window` (`accounts-v1` §5).
    ///
    /// Runs the shared probe with `--session <tmux> --codex-reset <key>` on that window's host; the
    /// probe asks that very Codex to consume the credit and reads its limits again.
    func codexReset(
        workspace: UniConnectAccountsInput.Workspace,
        window: UniConnectAccountsInput.Window,
        idempotencyKey: String
    ) async -> Result<CodexResetResult, ProbeFailure> {
        guard let session = window.tmuxSession else { return .failure(ProbeFailure(code: "sin_tmux")) }
        let target: Job.Target
        switch workspace.kind {
        case .local:
            guard let socket = window.tmuxSocket else { return .failure(ProbeFailure(code: "sin_tmux")) }
            target = .local(socket: socket)
        case .ssh:
            guard let credentialID = workspace.credentialID else { return .failure(ProbeFailure(code: "ssh_fallo")) }
            target = .ssh(credentialID: credentialID)
        }
        let job = Job(
            id: "reset", hostKey: workspace.hostKey, target: target, sessions: [session],
            mode: ["--codex-reset", idempotencyKey]
        )
        switch await run(job, script: probeScript(), timeout: .seconds(20)) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let output):
            guard let reset = output.codexReset else { return .failure(ProbeFailure(code: "salida_no_valida")) }
            if let error = reset.error { return .failure(ProbeFailure(code: String(error.prefix(40)))) }
            guard let outcome = reset.outcome else { return .failure(ProbeFailure(code: "salida_no_valida")) }
            return .success(CodexResetResult(outcome: outcome, usage: reset.usage.flatMap(Self.usage(_:))))
        }
    }

    private let processRunner: any UniConnectProcessRunning
    private let credentialResolver: CredentialResolver
    private let probeScript: @Sendable () -> String?
    private let ambientEnvironment: @Sendable () -> [String: String]
    private let history: UniConnectAccountsHistoryStore
    private let localPython: String
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private var inFlight: Task<UniConnectAccountsSnapshot, Never>?

    init(
        processRunner: any UniConnectProcessRunning,
        credentialResolver: @escaping CredentialResolver,
        history: UniConnectAccountsHistoryStore,
        probeScript: @escaping @Sendable () -> String? = {
            UniConnectRemoteAgentProbe.bundledScript(named: "agent_probe")
        },
        ambientEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        localPython: String = "/usr/bin/python3",
        timeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        self.credentialResolver = credentialResolver
        self.history = history
        self.probeScript = probeScript
        self.ambientEnvironment = ambientEnvironment
        self.localPython = localPython
        self.timeout = timeout
        self.now = now
    }

    /// Reads every window of `input` now; a call during another reading shares its result.
    func read(_ input: UniConnectAccountsInput) async -> UniConnectAccountsSnapshot {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.perform(input) }
        inFlight = task
        let snapshot = await task.value
        inFlight = nil
        return snapshot
    }

    private func perform(_ input: UniConnectAccountsInput) async -> UniConnectAccountsSnapshot {
        var jobs: [String: Job] = [:]
        var vaultClosedHosts: Set<String> = []
        var hostOrder: [String] = []
        var hostLabels: [String: (label: String, kind: String)] = [:]
        for workspace in input.workspaces {
            if hostLabels[workspace.hostKey] == nil {
                hostOrder.append(workspace.hostKey)
                hostLabels[workspace.hostKey] = (workspace.hostLabel, workspace.kind == .local ? "local" : "ssh")
            }
            let sessions = workspace.windows.compactMap(\.tmuxSession)
            switch workspace.kind {
            case .local:
                for window in workspace.windows {
                    guard let socket = window.tmuxSocket, let session = window.tmuxSession else { continue }
                    let id = "local:" + socket
                    let existing = jobs[id]
                    jobs[id] = Job(
                        id: id, hostKey: workspace.hostKey, target: .local(socket: socket),
                        sessions: (existing?.sessions ?? []) + [session]
                    )
                }
            case .ssh:
                guard let credentialID = workspace.credentialID else {
                    vaultClosedHosts.insert(workspace.hostKey)
                    continue
                }
                guard !sessions.isEmpty else { continue }
                let id = "ssh:" + credentialID.uuidString
                let existing = jobs[id]
                jobs[id] = Job(
                    id: id, hostKey: workspace.hostKey, target: .ssh(credentialID: credentialID),
                    sessions: (existing?.sessions ?? []) + sessions
                )
            }
        }

        let script = probeScript()
        var outputs: [String: UniConnectAccountsProbeOutput] = [:]
        var failures: [String: String] = [:]
        var finishedAt: [String: Date] = [:]
        await withTaskGroup(of: (String, Result<UniConnectAccountsProbeOutput, ProbeFailure>, Date).self) { group in
            for job in jobs.values {
                group.addTask { [self] in
                    let output = await self.run(job, script: script)
                    return (job.id, output, Date())
                }
            }
            for await (id, output, at) in group {
                switch output {
                case .success(let value): outputs[id] = value
                case .failure(let failure): failures[id] = failure.code
                }
                finishedAt[id] = at
            }
        }

        let checkedAt = now()
        var hostStates: [String: UniConnectAccountsSnapshot.HostState] = [:]
        var hostErrors: [String: String] = [:]
        var hostCheckedAt: [String: Date] = [:]
        for job in jobs.values {
            let ok = outputs[job.id] != nil
            if !ok || hostStates[job.hostKey] == nil { hostStates[job.hostKey] = ok ? .ok : .hostUnreachable }
            if let failure = failures[job.id] { hostErrors[job.hostKey] = failure }
            hostCheckedAt[job.hostKey] = max(hostCheckedAt[job.hostKey] ?? .distantPast, finishedAt[job.id] ?? checkedAt)
        }
        for key in vaultClosedHosts where hostStates[key] == nil {
            hostStates[key] = .vaultClosed
        }
        let hosts = hostOrder.map { key -> UniConnectAccountsSnapshot.Host in
            let label = hostLabels[key] ?? (key, "ssh")
            return UniConnectAccountsSnapshot.Host(
                key: key, label: label.label, kind: label.kind,
                state: hostStates[key] ?? .ok,
                checkedAt: hostCheckedAt[key] ?? checkedAt,
                error: hostErrors[key]
            )
        }

        var windows: [UniConnectAccountsSnapshot.Window] = []
        for workspace in input.workspaces {
            let hostState = hostStates[workspace.hostKey] ?? .ok
            for window in workspace.windows {
                let jobID: String? = switch workspace.kind {
                case .local: window.tmuxSocket.map { "local:" + $0 }
                case .ssh: workspace.credentialID.map { "ssh:" + $0.uuidString }
                }
                windows.append(Self.window(
                    workspace: workspace,
                    window: window,
                    hostState: hostState,
                    output: jobID.flatMap { outputs[$0] }
                ))
            }
        }

        let summaries = Self.summaries(windows)
        let recorded = await history.record(
            Dictionary(summaries.compactMap { summary in summary.usage.map { (summary.key, $0) } },
                       uniquingKeysWith: { first, _ in first }),
            keys: summaries.map(\.key),
            now: checkedAt
        )
        let accounts = summaries.map { summary in
            UniConnectAccountsSnapshot.AccountSummary(
                key: summary.key, provider: summary.provider, displayName: summary.displayName,
                email: summary.email, plan: summary.plan, organization: summary.organization,
                windows: summary.windows, hostKeys: summary.hostKeys, usage: summary.usage,
                history: recorded[summary.key] ?? []
            )
        }
        return UniConnectAccountsSnapshot(checkedAt: checkedAt, hosts: hosts, windows: windows, accounts: accounts)
    }

    /// One window by the first rule of `accounts-v1` §3 that applies.
    private static func window(
        workspace: UniConnectAccountsInput.Workspace,
        window: UniConnectAccountsInput.Window,
        hostState: UniConnectAccountsSnapshot.HostState,
        output: UniConnectAccountsProbeOutput?
    ) -> UniConnectAccountsSnapshot.Window {
        func make(
            _ state: UniConnectAccountsSnapshot.WindowState,
            agent: UniConnectAccountsSnapshot.Agent? = nil,
            account: UniConnectAccountsSnapshot.Account? = nil
        ) -> UniConnectAccountsSnapshot.Window {
            UniConnectAccountsSnapshot.Window(
                workspaceID: workspace.id, workspace: workspace.name, terminalID: window.id,
                window: window.name, hostKey: workspace.hostKey, tmuxSession: window.tmuxSession,
                state: state, agent: agent, account: account
            )
        }
        guard hostState == .ok else { return make(.hostUnreachable) }
        guard let session = window.tmuxSession else { return make(.noTmux) }
        guard let output else { return make(.hostUnreachable) }
        guard let probed = output.sessions.first(where: { $0.name == session }) else { return make(.sessionNotLive) }
        switch probed.reason {
        case "sin_ia": return make(.noAgent)
        case "identidad_ambigua": return make(.ambiguous)
        case "panel_muerto": return make(.deadPane)
        default: break
        }
        guard let probedAgent = probed.agent else { return make(.noAgent) }
        let agent = UniConnectAccountsSnapshot.Agent(
            provider: probedAgent.provider,
            displayName: displayName(provider: probedAgent.provider),
            asRoot: probedAgent.asRoot ?? false
        )
        guard let probedAccount = probedAgent.account else { return make(.unknown, agent: agent) }
        let state = UniConnectAccountsSnapshot.WindowState(rawValue: probedAccount.state) ?? .unknown
        let account = UniConnectAccountsSnapshot.Account(
            email: probedAccount.email,
            method: probedAccount.method,
            plan: probedAccount.plan,
            organization: probedAccount.organization,
            osUser: probedAccount.osUser,
            config: probedAccount.config,
            readAt: probedAccount.readAt.flatMap(date(_:)),
            usage: probedAccount.usage.flatMap(usage(_:))
        )
        return make(state, agent: agent, account: account)
    }

    private struct Summary {
        let key: String
        let provider: String
        let displayName: String
        let email: String
        let plan: String?
        let organization: String?
        var windows: Int
        var hostKeys: [String]
        var usage: UniConnectAccountsSnapshot.Usage?
    }

    /// Accounts by provider + email, most windows first; each with its most recent usage.
    private static func summaries(_ windows: [UniConnectAccountsSnapshot.Window]) -> [Summary] {
        var order: [String] = []
        var byKey: [String: Summary] = [:]
        for window in windows where window.state == .ok {
            guard let agent = window.agent, let account = window.account, let email = account.email else { continue }
            let key = UniConnectAccountsSnapshot.accountKey(provider: agent.provider, email: email)
            var summary = byKey[key] ?? Summary(
                key: key, provider: agent.provider, displayName: agent.displayName, email: email,
                plan: account.plan, organization: account.organization, windows: 0, hostKeys: [], usage: nil
            )
            if byKey[key] == nil { order.append(key) }
            summary.windows += 1
            if !summary.hostKeys.contains(window.hostKey) { summary.hostKeys.append(window.hostKey) }
            if var usage = account.usage, usage.observedAt > (summary.usage?.observedAt ?? .distantPast) {
                usage.hostKey = window.hostKey
                summary.usage = usage
            }
            byKey[key] = summary
        }
        return order.compactMap { byKey[$0] }.sorted {
            $0.windows != $1.windows ? $0.windows > $1.windows : $0.email < $1.email
        }
    }

    /// Why one host's probe failed, as `hosts[].error` of `accounts-v1`.
    struct ProbeFailure: Error {
        let code: String
    }

    /// Runs the probe for one host and says why it failed (no python3, timeout, SSH, output).
    private func run(
        _ job: Job,
        script: String?,
        timeout runTimeout: Duration? = nil
    ) async -> Result<UniConnectAccountsProbeOutput, ProbeFailure> {
        guard let script, !script.isEmpty else { return .failure(ProbeFailure(code: "sin_sonda")) }
        let sessionArguments = job.sessions.flatMap { ["--session", $0] }
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        switch job.target {
        case .local(let socket):
            guard FileManager.default.isExecutableFile(atPath: localPython) else {
                return .failure(ProbeFailure(code: "sin_python3"))
            }
            executable = localPython
            arguments = ["-", "--socket", socket] + job.mode + sessionArguments
            environment = localEnvironment()
        case .ssh(let credentialID):
            guard let record = await credentialResolver(credentialID),
                  let session = UniConnectSSH.detectedSession(fromCredentialRecord: record) else {
                return .failure(ProbeFailure(code: "ssh_fallo"))
            }
            let remoteCommand = (["python3", "-", "--socket", "default"] + job.mode + sessionArguments)
                .map(UniConnectSSH.shellQuote)
                .joined(separator: " ")
            guard let invocation = UniConnectSSHProcessInvocation(
                session: session,
                remoteCommand: remoteCommand,
                ambientEnvironment: ambientEnvironment()
            ) else { return .failure(ProbeFailure(code: "ssh_fallo")) }
            executable = invocation.executable
            arguments = invocation.arguments
            environment = invocation.environment
        }
        let result: UniConnectProcessResult
        do {
            result = try await processRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: Data(script.utf8),
                timeout: runTimeout ?? timeout
            )
        } catch UniConnectProcessRunnerError.timedOut {
            return .failure(ProbeFailure(code: "sin_respuesta"))
        } catch {
            return .failure(ProbeFailure(code: "ssh_fallo"))
        }
        let stderr = String(decoding: result.standardError.prefix(4_096), as: UTF8.self).lowercased()
        if result.terminationStatus == 127
            || (stderr.contains("python3") && (stderr.contains("not found") || stderr.contains("no such file"))) {
            return .failure(ProbeFailure(code: "sin_python3"))
        }
        if result.terminationStatus == 255 { return .failure(ProbeFailure(code: "ssh_fallo")) }
        guard !result.outputWasTruncated,
              let output = UniConnectAccountsProbeOutput.decode(result.standardOutput) else {
            return .failure(ProbeFailure(code: "salida_no_valida"))
        }
        if let error = output.error { return .failure(ProbeFailure(code: String(error.prefix(40)))) }
        return .success(output)
    }

    /// The probe's environment on this Mac: enough to find tmux, its sockets and the user's files.
    private func localEnvironment() -> [String: String] {
        let ambient = ambientEnvironment()
        var environment: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": ambient["LANG"] ?? "es_ES.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "TMUX_TMPDIR"] {
            if let value = ambient[key], !value.isEmpty { environment[key] = value }
        }
        return environment
    }

    private static func usage(_ probed: UniConnectAccountsProbeOutput.Usage) -> UniConnectAccountsSnapshot.Usage? {
        guard let observedAt = date(probed.observedAt) else { return nil }
        return UniConnectAccountsSnapshot.Usage(
            source: probed.source,
            observedAt: observedAt,
            limits: probed.limits.map {
                UniConnectAccountsSnapshot.Limit(
                    id: $0.id, usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt.flatMap(date(_:)), windowMinutes: $0.windowMinutes
                )
            },
            hostKey: nil,
            resetCredits: probed.resetCredits.map {
                UniConnectAccountsSnapshot.ResetCredits(
                    available: $0.available, nextExpiresAt: $0.nextExpiresAt.flatMap(date(_:))
                )
            }
        )
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// «Claude Code», «Codex», «Antigravity», «Grok», or the provider id itself.
    static func displayName(provider: String) -> String {
        switch provider {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "agy": "Antigravity"
        case "grok": "Grok"
        default: provider
        }
    }
}
