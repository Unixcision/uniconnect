import CMUXAgentLaunch
import Foundation

/// Builds the «Detalles» of one window from what is saved and what a live check read, with the
/// rules of `contracts/window-details-v1/LEEME.md` (D3).
///
/// Pure: the coordinator gathers the inputs (records, vault, local inspector, SSH probe) and this
/// decides the `agent`, `reason`, `tmux` and host fields, so the rules are tested without an app.
///
/// - `agent`: the agent running now if the check saw exactly one (with or without id); else the
///   window's last saved agent, even if the window is now at a shell; else `nil`.
/// - `reason`: `sin_tmux` → `host_inaccesible` (any failed check, even with something saved) →
///   what the check said of the session (`panel_muerto` shown as `sin_ia`) → `nil`.
/// - `as_root`: the probe's; else the saved one; else whether the target's user is `root` (from
///   `host`, or from `host_label` when `host` is `nil`); local, `false`.
struct UniConnectWindowDetailsResolver: Sendable {
    /// The window's last saved agent.
    struct SavedAgent: Equatable, Sendable {
        /// A catalogue id or alias (`claude`, `codex`, `antigravity`, `agy`, …).
        let provider: String
        let sessionID: String?
        let workingDirectory: String?
        /// `nil` when it was never recorded.
        let asRoot: Bool?
        /// ``UniConnectWindowDetailsSnapshot/AgentState/saved`` or ``UniConnectWindowDetailsSnapshot/AgentState/interrupted``.
        let state: UniConnectWindowDetailsSnapshot.AgentState
        /// The last time it was seen live, when known.
        let observedAt: Date?
    }

    /// The agent the live check found (exactly one), with or without id.
    struct LiveAgent: Equatable, Sendable {
        let provider: String
        let sessionID: String?
        let workingDirectory: String?
        let asRoot: Bool?
        /// `ficha`, `rollout`, `argv`; `nil` without id.
        let source: String?
    }

    /// What the live check read of the window's tmux session.
    enum LiveCheck: Equatable, Sendable {
        /// Nothing was checked yet (the modal's first frame).
        case notChecked
        /// The check failed or timed out, or the vault is closed: only what was saved is known.
        case failed
        /// The check worked and the session is not running.
        case sessionNotRunning(checkedAt: Date)
        /// The check saw the session.
        ///
        /// - Parameters:
        ///   - sessionID: The live `$N`.
        ///   - paneID: The live `%N` of the pane that decided.
        ///   - agent: The single agent, when there is exactly one.
        ///   - reason: `nil`, `sin_id`, `sin_ia`, `identidad_ambigua` or `panel_muerto`.
        ///   - hostUserID: The uid the SSH probe ran as, used for `as_root` when the agent does not say.
        ///   - checkedAt: When it was read.
        case sessionSeen(
            sessionID: String?, paneID: String?, agent: LiveAgent?, reason: String?,
            hostUserID: Int?, checkedAt: Date
        )
    }

    /// Everything saved about the window.
    struct Saved: Sendable {
        let workspaceID: UUID
        let terminalID: UUID
        let workspaceName: String
        let kind: UniConnectWindowDetailsSnapshot.Kind
        /// The resolved SSH target, `nil` locally or with the vault closed.
        let host: UniConnectWindowDetailsSnapshot.Host?
        /// The profile's label, used (normalised) when `host` is `nil`.
        let profileHostLabel: String?
        let windowName: String
        /// `nil` for an old window without tmux.
        let tmuxSocket: String?
        let tmuxSession: String?
        let agent: SavedAgent?
    }

    /// The shared no-prompt policy that derives the resume command and the display names.
    let policy: AgentNoPromptPolicy?

    /// The details for `saved` confirmed (or not) by `check`.
    ///
    /// - Returns: The snapshot and whether the live check worked (`false` for ``LiveCheck/failed``
    ///   and ``LiveCheck/notChecked``).
    func details(
        _ saved: Saved,
        check: LiveCheck,
        now: Date
    ) -> (details: UniConnectWindowDetailsSnapshot, confirmed: Bool) {
        let hostLabel: String?
        switch saved.kind {
        case .local:
            hostLabel = nil
        case .ssh:
            hostLabel = saved.host.map { Self.hostLabel(user: $0.user, hostname: $0.hostname, port: $0.port) }
                ?? saved.profileHostLabel.map(Self.normalizedHostLabel)
        }
        let targetUser = saved.host?.user ?? hostLabel.flatMap(Self.user(ofHostLabel:))
        var tmux: UniConnectWindowDetailsSnapshot.Tmux?
        if let socket = saved.tmuxSocket, let session = saved.tmuxSession {
            tmux = .init(socket: socket, session: session, sessionID: nil, paneID: nil, live: false)
        }
        var agent = saved.agent.map { savedAgent(from: $0, kind: saved.kind, targetUser: targetUser) }
        var reason: String?
        var confirmed = false
        if tmux == nil {
            reason = "sin_tmux"
            confirmed = check != .notChecked
        } else {
            switch check {
            case .notChecked:
                reason = nil
            case .failed:
                reason = "host_inaccesible"
            case .sessionNotRunning:
                reason = nil
                confirmed = true
            case let .sessionSeen(sessionID, paneID, live, liveReason, hostUserID, checkedAt):
                confirmed = true
                tmux?.sessionID = sessionID
                tmux?.paneID = paneID
                tmux?.live = true
                reason = liveReason == "panel_muerto" ? "sin_ia" : liveReason
                if let live, liveReason == nil || liveReason == "sin_id" {
                    let asRoot = live.asRoot
                        ?? hostUserID.map { $0 == 0 }
                        ?? (saved.kind == .ssh ? targetUser == "root" : false)
                    agent = makeAgent(
                        provider: live.provider,
                        sessionID: live.sessionID,
                        directory: live.workingDirectory,
                        asRoot: asRoot,
                        source: live.sessionID == nil ? nil : live.source,
                        state: .active,
                        observedAt: checkedAt
                    )
                    reason = live.sessionID == nil ? "sin_id" : nil
                }
            }
        }
        let snapshot = UniConnectWindowDetailsSnapshot(
            workspaceID: saved.workspaceID,
            terminalID: saved.terminalID,
            checkedAt: now,
            workspaceName: saved.workspaceName,
            kind: saved.kind,
            host: saved.kind == .ssh ? saved.host : nil,
            hostLabel: hostLabel,
            windowName: saved.windowName,
            tmux: tmux,
            agent: agent,
            reason: reason
        )
        return (snapshot, confirmed)
    }

    /// The agent block of what was saved, with `source: registro`.
    private func savedAgent(
        from saved: SavedAgent,
        kind: UniConnectWindowDetailsSnapshot.Kind,
        targetUser: String?
    ) -> UniConnectWindowDetailsSnapshot.Agent {
        let asRoot = saved.asRoot ?? (kind == .ssh ? targetUser == "root" : false)
        return makeAgent(
            provider: saved.provider,
            sessionID: saved.sessionID,
            directory: saved.workingDirectory,
            asRoot: asRoot,
            source: "registro",
            state: saved.state,
            observedAt: saved.observedAt
        )
    }

    /// The agent block, with its derived no-prompt resume command when it has an id.
    private func makeAgent(
        provider: String,
        sessionID: String?,
        directory: String?,
        asRoot: Bool,
        source: String?,
        state: UniConnectWindowDetailsSnapshot.AgentState,
        observedAt: Date?
    ) -> UniConnectWindowDetailsSnapshot.Agent {
        let wire = policy?.wireProvider(provider) ?? (provider == "antigravity" ? "agy" : provider)
        let resume = sessionID
            .flatMap { policy?.resume(provider: wire, sessionID: $0, asRoot: asRoot) }
            .map {
                UniConnectWindowDetailsSnapshot.Resume(
                    argv: $0.argv,
                    environment: $0.environment,
                    command: $0.shellLine(workingDirectory: directory),
                    noPromptVerified: $0.noPromptVerified
                )
            }
        return UniConnectWindowDetailsSnapshot.Agent(
            provider: wire,
            displayName: policy?.displayName(provider: wire) ?? wire,
            sessionID: sessionID,
            workingDirectory: directory,
            asRoot: asRoot,
            source: sessionID == nil ? nil : source,
            state: state,
            observedAt: observedAt,
            resume: resume
        )
    }

    /// Reads a local window through `inspector`: its live `$N`/`%N`, then one observation of its pane.
    ///
    /// No live ids means the session is not running (a check that worked); a pane that cannot be
    /// verified (no `target`, or no observation) is a failed check.
    ///
    /// - Parameters:
    ///   - inspector: The read-only local tmux inspector.
    ///   - binding: The window's tmux socket and session.
    ///   - target: The pane to observe, or `nil` when the window cannot be observed (hibernated).
    ///   - savedDirectory: The saved agent's folder, for an agent seen without one.
    static func localCheck(
        inspector: any UniConnectLocalTmuxInspecting,
        binding: UniConnectLocalTmuxBinding,
        target: UniConnectLocalTmuxRuntimeObservation.Target?,
        savedDirectory: String?
    ) async -> LiveCheck {
        guard let identity = await inspector.liveIdentity(binding: binding) else {
            return .sessionNotRunning(checkedAt: Date())
        }
        guard let target, let state = await inspector.runtimeObservations(for: [target]).first?.state else {
            return .failed
        }
        return localCheck(identity: identity, observation: state, checkedAt: Date(), savedDirectory: savedDirectory)
    }

    /// Turns one local observation into the live check.
    static func localCheck(
        identity: UniConnectLocalTmuxLiveIdentity,
        observation: UniConnectLocalTmuxRuntimeObservation.State,
        checkedAt: Date,
        savedDirectory: String?
    ) -> LiveCheck {
        switch observation {
        case .discovered(let observed):
            let live = LiveAgent(
                provider: observed.provider.rawValue,
                sessionID: observed.sessionID,
                workingDirectory: observed.workingDirectory.map { AgentResumeWorkingDirectory().realPath($0) },
                asRoot: observed.asRoot,
                source: observed.source.rawValue
            )
            return .sessionSeen(
                sessionID: identity.sessionID, paneID: identity.paneID, agent: live, reason: nil,
                hostUserID: nil, checkedAt: checkedAt
            )
        case .unidentified(let provider, let directory):
            let live = LiveAgent(
                provider: provider.rawValue,
                sessionID: nil,
                workingDirectory: directory.map { AgentResumeWorkingDirectory().realPath($0) } ?? savedDirectory,
                asRoot: false,
                source: nil
            )
            return .sessionSeen(
                sessionID: identity.sessionID, paneID: identity.paneID, agent: live, reason: "sin_id",
                hostUserID: nil, checkedAt: checkedAt
            )
        case .ambiguous:
            return .sessionSeen(
                sessionID: identity.sessionID, paneID: identity.paneID, agent: nil, reason: "identidad_ambigua",
                hostUserID: nil, checkedAt: checkedAt
            )
        case .shell:
            return .sessionSeen(
                sessionID: identity.sessionID, paneID: identity.paneID, agent: nil, reason: "sin_ia",
                hostUserID: nil, checkedAt: checkedAt
            )
        case .agent:
            // Legacy reading the service no longer emits: it proves nothing about now.
            return .failed
        }
    }

    /// Turns what the SSH probe read of one session into the live check.
    ///
    /// - Parameters:
    ///   - report: The probe's report, or `nil` when the box did not answer in time.
    ///   - session: The window's tmux session name.
    ///   - checkedAt: When it was read.
    static func remoteCheck(report: AgentProbeReport?, session: String, checkedAt: Date) -> LiveCheck {
        guard let report, report.error == nil else { return .failed }
        guard let found = report.session(named: session) else {
            // Missing from a complete reading: not running. From a cut one: nothing is known.
            return report.missingMeansGone ? .sessionNotRunning(checkedAt: checkedAt) : .failed
        }
        let agent = found.agent.map {
            LiveAgent(
                provider: $0.provider, sessionID: $0.sessionID, workingDirectory: $0.workingDirectory,
                asRoot: $0.asRoot, source: $0.source
            )
        }
        return .sessionSeen(
            sessionID: found.sessionID, paneID: found.paneID, agent: agent, reason: found.reason,
            hostUserID: report.uid, checkedAt: checkedAt
        )
    }

    /// `user@hostname:port`, with an IPv6 address between brackets.
    static func hostLabel(user: String, hostname: String, port: Int) -> String {
        let host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        return "\(user)@\(host):\(port)"
    }

    /// A saved profile label in the wire's `usuario@host:puerto` form (`:22` when it has none).
    ///
    /// A label without user (an `~/.ssh/config` alias) travels as `host:puerto`; an unbracketed
    /// IPv6 address is put between brackets.
    static func normalizedHostLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        var user: String?
        var rest = trimmed
        if let at = trimmed.lastIndex(of: "@") {
            user = String(trimmed[..<at])
            rest = String(trimmed[trimmed.index(after: at)...])
        }
        var host = rest
        var port = "22"
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[...close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":"), let value = Int(tail.dropFirst()), value > 0 { port = String(value) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":"),
                  let value = Int(rest[rest.index(after: colon)...]), value > 0 {
            host = String(rest[..<colon])
            port = String(value)
        } else if rest.contains(":") {
            host = "[\(rest)]"
        }
        guard let user, !user.isEmpty else { return "\(host):\(port)" }
        return "\(user)@\(host):\(port)"
    }

    /// The user part of `usuario@host:puerto`, or `nil` without one.
    static func user(ofHostLabel label: String) -> String? {
        guard let at = label.lastIndex(of: "@") else { return nil }
        let user = String(label[..<at])
        return user.isEmpty ? nil : user
    }
}
